#!/usr/bin/python3 -I
# Installed in place of each Python helper (see the Makefile), named after it:
# runs the helper's code, installed beside this as the module @MODULE@.py, from
# the bytecode compiled when the package was built. A helper run as a script
# is compiled again on every start -- about 40 ms for the state helper, which
# a theme change starts a dozen times. Bytecode comes only from this
# root-owned directory: -I keeps the user's site-packages, PYTHONPATH and the
# current directory out of sys.path, and nothing is written at run time.
import sys
sys.dont_write_bytecode = True
import os
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import runpy
runpy.run_module("@MODULE@", run_name="__main__", alter_sys=True)
