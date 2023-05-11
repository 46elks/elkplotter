#!/usr/bin/env python3
import time

import websocket
from pyaxidraw import axidraw

import config

ad = axidraw.AxiDraw()

ws = websocket.WebSocket()
ws.connect(config.SERVER)

cooldown = getattr(config, 'COOLDOWN', None)

hello = ws.recv()
if hello != "hello!":
    raise Exception("Invalid hello from server.")

ws.send("hello, server!")
while True:
    print("Sending ready to server.")
    ws.send("ready.")
    command = ws.recv()
    if not command.startswith("pleaseplot: "):
        print("Got unknown command from server: ", command[:20])
        continue
    print("Starting plot!")
    svg = command.removeprefix("pleaseplot: ")
    try:
        ad.plot_setup(svg)
    except RuntimeError:
        print("Got invalid SVG from server.")
        continue
    if config.DEBUG:
        ad.options.preview = True
    ad.plot_run()
    print("Plot done.")
    if cooldown:
        print(f"Cooling down for {cooldown} seconds...")
        time.sleep(cooldown)
