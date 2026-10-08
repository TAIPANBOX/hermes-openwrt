#!/usr/bin/env python3
# tool-output.py -- what the agent's tools returned since a moment, from Hermes's own conversation
# database. Runs ON the router as root; hw-flow.sh copies it there. agent.log records only that a
# tool ran and how many characters it returned, so this is where a check reads what it returned.
#   python3 tool-output.py <unix seconds>
import sqlite3
import sys

db = sqlite3.connect("file:/srv/hermes/state.db?mode=ro", uri=True)
for (content,) in db.execute("select content from messages where role = 'tool' and timestamp > ? order by timestamp",
                             (float(sys.argv[1]),)):
    print(content or "")
