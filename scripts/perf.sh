#!/usr/bin/env bash

sysctl kernel.kptr_restrict=0
sudo sysctl kernel.perf_event_paranoid=-1