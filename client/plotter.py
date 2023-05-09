import websocket
from pyaxidraw import axidraw

import config

ad = axidraw.AxiDraw()

ws = websocket.WebSocket()
ws.connect(config.SERVER)

hello = ws.recv()
if hello != "hello!":
    raise Exception("Invalid hello from server.")

ws.send("hello, server!")
print("Sending ready to server.")
ws.send("ready.")
while True:
    command = ws.recv()
    if not command.startswith("pleaseplot: "):
        print("Got unknown command from server: ", command[:20])
        continue
    print("Starting plot!")
    svg = command.removeprefix("pleaseplot: ")
    ad.plot_setup(svg)
    if config.DEBUG:
        ad.options.preview = True
    ad.plot_run()
    print("Plot done, sending ready to server.")
    ws.send("ready.")
