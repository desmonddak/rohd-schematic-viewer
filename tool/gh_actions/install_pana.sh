#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# install_pana.sh
# GitHub Actions step: Install Pana analysis.

set -euo pipefail

dart pub global activate pana
