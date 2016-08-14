#!/bin/bash

rm -rf .cabal-sandbox
rm -rf dist

cabal sandbox init
cabal sandbox add-source ../01-kask-base
cabal sandbox add-source ../02-treeprint

cabal install -j
