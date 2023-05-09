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
  Plotter = object
    websocket: WebSocket
    isReady: bool

let
  config = loadConfig("config.ini")

var
  L: Lock
  clients: OrderedTable[WebSocket, Plotter]

initLock(L)

proc dallE(prompt: string): string =
  var
    openAIkey: string
    imageWidth: string
    imageHeight: string

  {.gcsafe.}:
    withLock L:
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
    respData = response.body.parseJson()
    b64_json = respData["data"][0]["b64_json"]

  result = decode(b64_json.str)

proc vpype(inpath, outpath: string) =
  discard execShellCmd(
    fmt"""
    vpype \
    iread {inpath} \
    linesimplify -t 1 \
    filter -m 10 \
    penwidth 0.3mm \
    layout --fit-to-margins 3cm --landscape a6 \
    write {outpath}
    """
  )

proc generateImage(prompt: string): string =
  let image = dallE(prompt)

  let (imgfile, inpath) = createTempFile("elkplotter_", "_orig.png")
  imgfile.write(image)
  close imgfile

  let (tracefile, outpath) = createTempFile("elkplotter_", "_traced.svg")
  close tracefile
  vpype(inpath, outpath)

  removeFile(inpath)

  return outpath

proc smsHandler(request: Request) {.gcsafe.} =
  let
    data = request.body.parseSearch()
    userPrompt = data["message"]
    smsTimestamp = data["created"]
    smsdt = smsTimestamp.parse("yyyy-MM-dd'T'hh:mm:ss'.'ffffff", tz=utc())
    timedelta = now().utc - smsdt

  if timedelta > initDuration(minutes=1):
    request.respond(204)
    return

  var plotter: Plotter
  {.gcsafe.}:
    withLock L:
      if clients.len == 0:
        request.respond(204)
        echo "Got SMS, but no plotters connected."
        return
      block findPlotter:
        for ws, pl in clients.mpairs:
          if pl.isReady:
            echo fmt"Found plotter {plotter}"
            pl.isReady = false
            plotter = pl
            break findPlotter
        echo "Got SMS, but no vacant plotters."
        request.respond(200, body = "All plotters are busy right now, try again later! :)")
        return

  request.respond(204)

  var prompt: string
  {.gcsafe.}:
    withLock L:
      prompt = config.getSectionValue("Image", "prompt") & ", " & userPrompt

  let
    path = generateImage(prompt)
    image = readFile(path)
    wsMessage = "pleaseplot: " & image
  plotter.websocket.send(wsMessage)
  removeFile(path)

proc upgradeHandler(request: Request) =
  let websocket = request.upgradeToWebSocket()
  {.gcsafe.}:
    withLock L:
      websocket.send("hello!")

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
    let data = message.data.strip()
    echo message.kind, ": ", data
    if data == "ready.":
      echo fmt"Plotter {websocket} is ready."
      {.gcsafe.}:
        withLock L:
          clients[websocket].isReady = true
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
    hostname = config.getSectionValue("", "hostname")
    port = config.getSectionValue("", "port").parseInt()
    server = newServer(router, wsHandler)

  echo fmt"Serving on http://{hostname}:{port}"
  server.serve(Port(port), address = hostname)
