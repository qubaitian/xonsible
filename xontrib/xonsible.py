"""`xontrib load xonsible` puts on / bootstrap / run into the session."""

import xonsible


def _load_xontrib_(xsh, **_):
    return {name: getattr(xonsible, name) for name in ("on", "run", "bootstrap", "RemoteError")}
