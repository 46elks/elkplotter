==============
elkplotter.nim
==============

To compile, run

::

    nimble build

or

::

    nimble build -d:release

for release mode (no debug symbols or bounds checks).

We also need ``vpype`` and it's plugin ``vpype-vectrace`` available on ``$PATH``.

::

    pipx install vpype
    pipx inject vpype vpype-vectrace

The client connects via websocket to ``/ws``, it registeres the prompt and vpype
options to use and then tells the server when it is ready to receive images.
After being sent an image the client will not receive more images until it has
set itself to "ready" again.

SMS received while there is no client ready will be discarded, as will any SMS
older than 1 minute based on the "created" field sent by 46elks' API.
