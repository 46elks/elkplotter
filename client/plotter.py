#!/usr/bin/env python3
import json
import time

import websocket
from pyaxidraw import axidraw

import config

ad = axidraw.AxiDraw()

cooldown = getattr(config, 'COOLDOWN', None)

def plot(svg):
    try:
        ad.plot_setup(svg)
    except RuntimeError:
        print("Got invalid SVG from server.")
        return

    print("Received valid SVG!")
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


def main():
    ws = websocket.WebSocket()
    ws.connect(config.SERVER)

    print("Sending registration.")
    registration = {
        "method": "register",
        "params": {
            "prompt": config.PROMPT,
            "vpypeParams": " ".join(config.VPYPE_PARAMS)
        }
    }
    ws.send(json.dumps(registration))
    reg_result = ws.recv()
    assert json.loads(reg_result)["result"] == "registered"

    while True:
        print("Sending ready to server.")
        ws.send("""{"method": "ready"}""")
        ready_ok = ws.recv()
        assert json.loads(ready_ok)["result"] == "readyok"

        message = ws.recv()
        try:
            data = json.loads(message)
        except ValueError:
            print("Could not parse message.")
            continue

        if data.get("method") == "plot":
            svg = data["params"]["image"]
            plot(svg)
        else:
            print("Got unknown method from server: ", data)
            continue


if __name__ == "__main__":
    main()
