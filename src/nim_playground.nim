import jester, asyncdispatch, os, osproc, strutils, json, threadpool, asyncfile, asyncnet, posix, logging, nuuid, tables, httpclient, streams, uri
import ansitohtml, ansiparse, sequtils

type
  Config = object
    tmpDir: ptr string
    logFile: ptr string

  APIToken = object
    gist: string

  ParsedRequest = object
    code: string
    compilationTarget: string

  RequestConfig = object
    tmpDir: string

  OutputFormat = enum
    Raw, HTML, Ansi, AnsiParsed

const configFileName = "conf.json"

onSignal(SIGABRT):
  ## Handle SIGABRT from systemd
  # Lines printed to stdout will be received by systemd and logged
  # Start with "<severity>" from 0 to 7
  echo "<2>Received SIGABRT"
  quit(1)

var conf = createShared(Config)
let parsedConfig = parseFile(configFileName)
var
  tmpDir = parsedConfig["tmp_dir"].str
  logFile = parsedConfig["log_fname"].str

discard existsOrCreateDir(tmpDir)

conf.tmpDir = tmpDir.addr
conf.logFile = logFile.addr

let fl = newFileLogger(conf.logFile[], fmtStr = "$datetime $levelname ")
fl.addHandler

proc `%`(c: char): JsonNode =
  %($c)

proc respondOnReady(fv: FlowVar[TaintedString], requestConfig: ptr RequestConfig, output: OutputFormat): Future[string] {.async.} =
  while true:
    if fv.isReady:
      echo ^fv

      var errorsFile = openAsync("$1/errors.txt" % requestConfig.tmpDir, fmRead)
      var logFile = openAsync("$1/logfile.txt" % requestConfig.tmpDir, fmRead)
      var errors = await errorsFile.readAll()
      var log = await logFile.readAll()

      template cleanAndColourize(x: string): string =
        x
          .multiReplace([("<", "&lt;"), (">", "&gt;"), ("\n", "<br/>")])
          .ansiToHtml({"31": "color: red", "32": "color: #66d9ef", "36": "color: #50fa7b"}.toTable)

      template clearAnsi(y: string): string =
        y.parseAnsi
          .filter(proc (x: AnsiData): bool = x.kind == String)
          .map(proc (x: AnsiData): string = x.str)
          .join()

      var ret: JsonNode

      case output:
      of HTML:
        ret = %* {"compileLog": cleanAndColourize(errors),
                  "log": cleanAndColourize(log)}
      of Ansi:
        ret = %* {"compileLog": errors, "log": log}
      of AnsiParsed:
        ret = %* {"compileLog": errors.parseAnsi, "log": log.parseAnsi}
      of Raw:
        ret = %* {"compileLog": errors.clearAnsi, "log": log.clearAnsi}

      errorsFile.close()
      logFile.close()
      discard execProcess("sudo -u nobody /bin/chmod a+w $1/*" % [requestConfig.tmpDir])
      removeDir(requestConfig.tmpDir)
      freeShared(requestConfig)
      return $ret


    await sleepAsync(500)

proc prepareAndCompile(code, compilationTarget: string, requestConfig: ptr RequestConfig, version: string): TaintedString =
  discard existsOrCreateDir(requestConfig.tmpDir)
  copyFileWithPermissions("./test/script.sh", "$1/script.sh" % requestConfig.tmpDir)
  writeFile("$1/in.nim" % requestConfig.tmpDir, code)
  echo execProcess("chmod a+w $1" % [requestConfig.tmpDir])

  let cmd = ("""
    ./docker_timeout.sh 20s -i -t --net=none -v "$1":/usercode --user nobody virtual_machine:""" & version & """ /usercode/script.sh in.nim $2
    """) % [requestConfig.tmpDir, compilationTarget]

  execProcess(cmd)

proc loadUrl(url: string): Future[string] {.async.} =
  let client = newAsyncHttpClient()
  client.onProgressChanged = proc (total, progress, speed: BiggestInt) {.async.} =
    if total > 1048576 or progress > 1048576 or (progress > 4000 and speed < 100):
      client.close()
  return await client.getContent(url)

proc createIx(code: string): string =
  let client = newHttpClient()
  var data = newMultipartData()
  data["f:1"] = code
  client.postContent("http://ix.io", multipart = data)[0..^2] & "/nim"

proc loadIx(ixid: string): Future[string] {.async.} =
  try:
    return await loadUrl("http://ix.io/$1" % ixid)
  except:
    return "Unable to load ix paste, file too large, or download is too slow"

proc compile(code, compilationTarget: string, output: OutputFormat, requestConfig: ptr RequestConfig, version: string): Future[string] =
  let fv = spawn prepareAndCompile(code, compilationTarget, requestConfig, version)
  return respondOnReady(fv, requestConfig, output)

proc isVersion(ver: string): bool =
  let parts = ver.split('.')
  if parts.len != 3:
    return false
  if parts[0][0] != 'v':
    return false
  else:
    if not parts[0][1..^1].isDigit or not parts[1].isDigit or not parts[2].isDigit:
      return false
  return ver in execProcess("docker images | sed -n 's/virtual_machine *\\(v[^ ]*\\).*/\\1/p' | sort --version-sort").split("\n")[0..^2]

routes:
  get "/index.html#@extra":
    redirect "/#" & @"extra"

  get "/index.html":
    redirect "/"

  get "/":
    resp readFile("public/index.html")

  get "/versions":
    resp $(%*{"versions": execProcess("docker images | sed -n 's/virtual_machine *\\(v[^ ]*\\).*/\\1/p' | sort --version-sort").split("\n")[0..^2]})

  get "/tour/@url":
      resp(Http200, [("Content-Type","text/plain")], await loadUrl(decodeUrl(@"url")))

  get "/ix/@ixid":
      resp(Http200, await loadIx(@"ixid"))

  post "/ix":
    var parsedRequest: ParsedRequest
    let parsed = parseJson(request.body)
    if getOrDefault(parsed, "code").isNil:
      resp(Http400)
    parsedRequest = to(parsed, ParsedRequest)

    resp(Http200, @[("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Methods", "POST")], createix(parsedRequest.code))

  post "/compile":
    var parsedRequest: ParsedRequest

    var
      outputFormat = Raw
      version = "latest"
    if request.params.len > 0:
      if request.params.hasKey("code"):
        parsedRequest.code = request.params["code"]
      if request.params.hasKey("compilationTarget"):
        parsedRequest.compilationTarget = request.params["compilationTarget"]
      if request.params.hasKey("outputFormat"):
        try:
          outputFormat = parseEnum[OutputFormat](request.params["outputFormat"])
        except:
          resp(Http400)
      if request.params.hasKey("version"):
        version = request.params["version"]
    else:
      let parsed = parseJson(request.body)
      if getOrDefault(parsed, "code").isNil:
        resp(Http400, "{\"error\":\"No code\"")
      if getOrDefault(parsed, "compilationTarget").isNil:
        resp(Http400, "{\"error\":\"No compilation target\"}")
      parsedRequest = to(parsed, ParsedRequest)
      if parsed.hasKey("outputFormat"):
        try:
          outputFormat = parseEnum[OutputFormat](parsed["outputFormat"].str)
        except:
          resp(Http400, "{\"error\":\"Invalid output format\"")
      if parsed.hasKey("version"):
        version = parsed["version"].str

    if version != "latest" and not version.isVersion:
      resp(Http400, "{\"error\":\"Unknown version\"}")

    let requestConfig = createShared(RequestConfig)
    requestConfig.tmpDir = conf.tmpDir[] & "/" & generateUUID()
    let compileResult = await compile(parsedRequest.code, parsedRequest.compilationTarget, outputFormat, requestConfig, version)

    resp(Http200, [("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Methods", "POST")], compileResult)


info "Starting!"
runForever()
freeShared(conf)
