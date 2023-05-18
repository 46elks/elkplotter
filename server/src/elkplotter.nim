import std/[
  base64,
  httpclient,
  json,
  locks,
  os,
  parsecfg,
  strformat,
  strutils,
  tables,
  tempfiles,
  times
]
import mummy, mummy/routers
import webby

type
  PlotterConfig = object
    prompt: string
    vpypeParams: string
  Plotter = object
    websocket: WebSocket
    config: PlotterConfig
    isRegistered: bool
    isReady: bool
  HttpError = object of IOError

let
  globalConfig = loadConfig("config.ini")

var
  L: Lock
  clients: Table[WebSocket, Plotter]
  tlsConfig {.threadvar.}: Config

initLock(L)

proc getConfig(): Config =
  if tlsConfig.isNil:
    {.gcsafe.}:
      withLock L:
        tlsConfig = globalConfig
  result = tlsConfig

proc dallE(prompt: string): string =
  let
    config = getConfig()
    openAIkey = config.getSectionValue("OpenAI", "apikey")
    imageWidth = config.getSectionValue("OpenAI", "width")
    imageHeight = config.getSectionValue("OpenAI", "height")

  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & openAIkey,
    "Content-Type": "application/json"
  })

  let
    data = %*
      { "prompt": prompt
      , "n": 1
      , "size": fmt"{imageWidth}x{imageHeight}"
      , "response_format": "b64_json"
      }
    response = client.post("https://api.openai.com/v1/images/generations", body = $data)

  if not response.code.is2xx:
    raise newException(HttpError,
                       &"Got HTTP {response.code} from OpenAI, body:\n{response.body}")

  let
    respData = response.body.parseJson()
    b64_json = respData["data"][0]["b64_json"]
  result = decode(b64_json.str)

proc vpype(inpath, outpath, params: string) =
  discard execShellCmd(fmt"vpype iread {inpath} {params} write {outpath}")

proc generateImage(prompt: string, vpypeParams: string): string =
  let image = dallE(prompt)

  let (imgfile, inpath) = createTempFile("elkplotter_", "_orig.png")
  imgfile.write(image)
  close imgfile

  let (tracefile, outpath) = createTempFile("elkplotter_", "_traced.svg")
  close tracefile
  vpype(inpath, outpath, vpypeParams)

  removeFile(inpath)
  result = outpath

proc smsHandler(request: Request) {.gcsafe.} =
  let
    config = getConfig()
    data = request.body.parseSearch()
    userPrompt = data["message"]
    smsTimestamp = data["created"]
    smsdt = smsTimestamp.parse("yyyy-MM-dd hh:mm:ss'.'ffffff", tz=utc())
    timedelta = now().utc - smsdt

  if timedelta > initDuration(minutes=1):
    request.respond(204)
    return

  var plotter: Plotter
  {.gcsafe.}:
    withLock L:
      if clients.len == 0:
        request.respond(204)
        echo "SMS received, but no plotters connected. Message: ", userPrompt
        return
      block findPlotter:
        for ws, pl in clients.mpairs:
          if pl.isReady:
            pl.isReady = false
            plotter = pl
            break findPlotter
        echo "SMS received, but no vacant plotters. Message: ", userPrompt
        request.respond(200, body = config.getSectionValue("", "sms_response_busy"))
        return

  request.respond(200, body = config.getSectionValue("", "sms_response_ack"))

  echo fmt"SMS received, found vacant plotter {plotter}."
  echo "Generating image for: ", userPrompt

  var
    wsMessage: string
    path: string
  try:
    let
      promptPrefix = plotter.config.prompt
      prompt = promptPrefix & ", " & userPrompt
    path = generateImage(prompt, plotter.config.vpypeParams)
    let image = readFile(path)
    wsMessage = $(%* {"method": "plot", "params": {"image": image}})
  except CatchableError as e:
    echo "Could not generate image."
    {.gcsafe.}:
      withLock L:
        clients[plotter.websocket].isReady = true
    raise e

  echo "Sending to plotter..."
  plotter.websocket.send(wsMessage)
  removeFile(path)

proc handleRpc(ws: WebSocket, s: string) =
  let j = parseJson(s)
  case j["method"].str
  of "register":
    let config = j["params"].to(PlotterConfig)
    {.gcsafe.}:
      withLock L:
        clients.withValue(ws, plotter):
          plotter.config = config
          plotter.isRegistered = true
    echo fmt"Plotter {ws} registered with: {config}"
    ws.send("""{"result": "registered"}""")
  of "ready":
    var res: string
    {.gcsafe.}:
      withLock L:
        clients.withValue(ws, plotter):
          if plotter.isRegistered:
            plotter.isReady = true
            res = """{"result": "readyok"}"""
            echo fmt"Plotter {ws} is ready."
          else:
            res = """{"error": "not registered"}"""
    ws.send(res)
  else:
    ws.send("""{"error": "bad request"}""")

proc upgradeHandler(request: Request) =
  discard request.upgradeToWebSocket()

proc wsHandler(websocket: WebSocket,
               event: WebSocketEvent,
               message: Message) {.gcsafe.} =
  case event
  of OpenEvent:
    echo "Client connected: ", websocket
    {.gcsafe.}:
      withLock L:
        clients[websocket] = Plotter(websocket: websocket, isReady: false)
  of MessageEvent:
    echo message.kind, ": ", message.data
    websocket.handleRpc(message.data)
  of CloseEvent:
    echo "Client disconnected: ", websocket
    {.gcsafe.}:
      withLock L:
        clients.del(websocket)
  of ErrorEvent:
    discard

when isMainModule:
  var router: Router
  router.post("/new-sms", smsHandler)
  router.get("/ws", upgradeHandler)

  let
    hostname = globalConfig.getSectionValue("", "hostname")
    port = globalConfig.getSectionValue("", "port").parseInt()
    server = newServer(router, wsHandler)

  echo fmt"Serving on http://{hostname}:{port}"
  server.serve(Port(port), address = hostname)
