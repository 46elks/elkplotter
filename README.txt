elkplotter.nim
==============

To compile, run

    nimble build

or

    nimble build -d:release

for release mode (no debug symbols, faster).

The client connects via websocket to /ws. When ready to plot, it sends "ready."

When an SMS has been received, and an svg has been generated, the client will
receive the svg prefixed by "pleaseplot: "

    pleaseplot: <?xml version="1.0" ...

The client will not receive any more images until it has sent "ready." again.

SMS received while there is no client ready will be discarded, as will any SMS
older than 1 minute based on the "created" field sent by 46elks' API.
