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

    svg = command.removeprefix("pleaseplot: ")
    try:
        ad.plot_setup(svg)
    except RuntimeError:
        print("Got invalid SVG from server.")
        continue

    print("Received SVG!")
    print()

    ad.options.report_time = True
    ad.options.preview = True
    ad.plot_run()

    if config.DEBUG:
        print("Debug mode active, twiddling thumbs...")
    else:
        print("Starting plot...\n")
        ad.options.preview = False
        ad.plot_run()
        print("\nPlot done!")

    print()

    if cooldown:
        print(f"Cooling down for {cooldown} seconds...")
        time.sleep(cooldown)
