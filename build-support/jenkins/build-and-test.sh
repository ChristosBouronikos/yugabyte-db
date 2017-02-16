#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# This script is invoked from the Jenkins builds to build YB
# and run all the unit tests.
#
# Environment variables may be used to customize operation:
#   BUILD_TYPE: Default: debug
#     Maybe be one of asan|tsan|debug|release|coverage|lint
#
#   BUILD_CPP
#   Default: 1
#     Build and test C++ code if this is set to 1.
#
#   SKIP_CPP_MAKE
#   Default: 0
#     Skip building C++ code, only run tests if this is set to 1 (useful for debugging).
#
#   BUILD_JAVA
#   Default: 1
#     Build and test java code if this is set to 1.
#
#   VALIDATE_CSD
#   Default: 0
#     If 1, runs the CM CSD validator against the YB CSD.
#     This requires access to an internal Cloudera maven repository.
#
#   BUILD_PYTHON
#   Default: 1
#     Build and test the Python wrapper of the client API.
#
#   DONT_DELETE_BUILD_ROOT
#   Default: 0
#     Skip deleting BUILD_ROOT (useful for debugging).
#
#   MVN_FLAGS
#   Default: ""
#     Extra flags which are passed to 'mvn' when building and running Java
#     tests. This can be useful, for example, to choose a different maven
#     repository location.
#
#   EXTRA_MAKE_ARGS
#     Extra arguments to pass to Make
#
# Portions Copyright (c) YugaByte, Inc.

set -e
# We pipe our build output to a log file with tee.
# This bash setting ensures that the script exits if the build fails.
set -o pipefail

. "${BASH_SOURCE%/*}/../common-test-env.sh"

if [[ $OSTYPE =~ ^darwin ]]; then
  # This is needed to make sure we're using Homebrew-installed CMake on Mac OS X.
  export PATH=/usr/local/bin:$PATH
fi

MAX_NUM_PARALLEL_TESTS=3

# If a commit messages contains a line that says 'DONT_BUILD', exit
# immediately.
set +e
DONT_BUILD=$( git show | egrep '^\s{4}DONT_BUILD$' )
set -e
if [ -n "$DONT_BUILD" ]; then
  echo "*** Build not requested. Exiting."
  exit 1
fi

set +e
SKIP_CPP_BUILD=$(git show|egrep '^\s{4}SKIP_CPP_BUILD$')
set -e
if [ -n "$SKIP_CPP_BUILD" ]; then
  BUILD_CPP="0"
else
  BUILD_CPP="1"
fi

# gather core dumps
ulimit -c unlimited

BUILD_TYPE=${BUILD_TYPE:-debug}
build_type=$BUILD_TYPE
normalize_build_type
readonly build_type
BUILD_TYPE=$build_type
readonly BUILD_TYPE

set_cmake_build_type_and_compiler_type

set_build_root --no-readonly

BUILD_JAVA=${BUILD_JAVA:-1}
VALIDATE_CSD=${VALIDATE_CSD:-0}
BUILD_PYTHON=${BUILD_PYTHON:-1}
DONT_DELETE_BUILD_ROOT=${DONT_DELETE_BUILD_ROOT:-0}
SKIP_CPP_MAKE=${SKIP_CPP_MAKE:-0}

LATEST_BUILD_LINK="$YB_SRC_ROOT/build/latest"
CTEST_OUTPUT_PATH="$BUILD_ROOT"/ctest.log
CTEST_FULL_OUTPUT_PATH="$BUILD_ROOT"/ctest-full.log

# Remove testing artifacts from the previous run before we do anything
# else. Otherwise, if we fail during the "build" step, Jenkins will
# archive the test logs from the previous run, thinking they came from
# this run, and confuse us when we look at the failed build.


if [[ -h $BUILD_ROOT ]]; then
  build_root_real_path=$( readlink "$BUILD_ROOT" )
  log "BUILD_ROOT ('$BUILD_ROOT') is a symlink to '$build_root_real_path'"
  # EPHEMERAL_DRIVES_FILTER_REGEX is not supposed to be anchored in the end, so we can add a "/".
  if [[ $build_root_real_path =~ $EPHEMERAL_DRIVES_FILTER_REGEX/ ]]; then
    log "Deleting '$build_root_real_path' because it is on an ephemeral drive."
    rm -rf "$build_root_real_path"
  else
    log "Not deleting '$build_root_real_path' because it is not on an ephemeral drive."
  fi
fi

if [[ $DONT_DELETE_BUILD_ROOT == "0" ]]; then
  log "Deleting BUILD_ROOT ('$BUILD_ROOT')."
  rm -rf "$BUILD_ROOT"
else
  YB_TEST_LOGS="$BUILD_ROOT/yb-test-logs"
  echo "Skip deleting BUILD_ROOT ('$BUILD_ROOT'), only deleting $YB_TEST_LOGS."
  rm -rf "$YB_TEST_LOGS"
fi

if [[ $DONT_DELETE_BUILD_ROOT == "0" || ! -d $BUILD_ROOT ]]; then
  create_dir_on_ephemeral_drive "$BUILD_ROOT" "build/${BUILD_ROOT##*/}"
fi

if [[ -h $BUILD_ROOT ]]; then
  # If we ended up creating BUILD_ROOT as a symlink to an ephemeral drive, now make BUILD_ROOT
  # actually point to the target of that symlink.
  BUILD_ROOT=$( readlink "$BUILD_ROOT" )
fi
readonly BUILD_ROOT

#
# Create or clean (if already present) a "test-workspace" directory
# in each ephemeral drive. Each test will randomly pick one of
# the drives for its working directory.
#
set +e
for ephemeral_dir in $(ls -d $EPHEMERAL_DRIVES_PATTERN 2> /dev/null); do
  work_dir="$ephemeral_dir"/test-workspace
  if [[ -d $work_dir ]]; then
    echo "Cleaning up old contents in $work_dir/*"
    rm -rf "$work_dir"/*
  else
    echo "Creating $work_dir"
    mkdir -p "$work_dir"
  fi
done
set -e

TEST_LOG_DIR="$BUILD_ROOT/test-logs"
TEST_TMP_ROOT_DIR="$BUILD_ROOT/test-tmp"

TEST_LOG_URL_PREFIX=""
if [ -n "${BUILD_URL:-}" ]; then
  BUILD_URL_NO_TRAILING_SLASH=${BUILD_URL%/}
  TEST_LOG_URL_PREFIX="${BUILD_URL_NO_TRAILING_SLASH}/artifact/build/$BUILD_TYPE_LOWER/test-logs"
fi

cleanup() {
  if [[ -n ${BUILD_ROOT:-} ]]; then
    echo "Running the script to clean up build artifacts..."
    export BUILD_ROOT
    "$YB_SRC_ROOT/build-support/jenkins/post-build-clean.sh"
  fi
}

# If we're running inside Jenkins (the BUILD_ID is set), then install
# an exit handler which will clean up all of our build results.
if [ -n "$BUILD_ID" ]; then
  trap cleanup EXIT
fi

export TOOLCHAIN_DIR=/opt/toolchain
if [ -d "$TOOLCHAIN_DIR" ]; then
  PATH=$TOOLCHAIN_DIR/apache-maven-3.0/bin:$PATH
fi

log "Starting third-party dependency build"
time thirdparty/build-thirdparty.sh
log "Third-party dependency build finished (see timing information above)"

THIRDPARTY_BIN=$YB_SRC_ROOT/thirdparty/installed/bin
export PPROF_PATH=$THIRDPARTY_BIN/pprof

if which ccache >/dev/null ; then
  CLANG=$YB_SRC_ROOT/build-support/ccache-clang/clang
else
  CLANG=$YB_SRC_ROOT/thirdparty/clang-toolchain/bin/clang
fi

# Configure the build
#
# ASAN/TSAN can't build the Python bindings because the exported YB client
# library (which the bindings depend on) is missing ASAN/TSAN symbols.

cd "$BUILD_ROOT"
cmake_cmd_line="cmake ${cmake_opts[@]}"
if [ "$BUILD_TYPE" = "asan" ]; then
  log "Starting ASAN build"
  time $cmake_cmd_line "$YB_SRC_ROOT"
  log "CMake invocation for ASAN build finished (see timing information above)"
  BUILD_PYTHON=0
elif [ "$BUILD_TYPE" = "tsan" ]; then
  log "Starting TSAN build"
  time cmake $cmake_cmd_line -DYB_USE_TSAN=1 "$YB_SRC_ROOT"
  log "CMake invocation for TSAN build finished (see timing information above)"
  EXTRA_TEST_FLAGS="$EXTRA_TEST_FLAGS -LE no_tsan"
  BUILD_PYTHON=0
elif [ "$BUILD_TYPE" = "coverage" ]; then
  DO_COVERAGE=1
  log "Starting coverage build"
  time $cmake_cmd_line -DYB_GENERATE_COVERAGE=1 "$YB_SRC_ROOT"
  log "CMake invocation for coverage build finished (see timing information above)"
elif [ "$BUILD_TYPE" = "lint" ]; then
  # Create empty test logs or else Jenkins fails to archive artifacts, which
  # results in the build failing.
  mkdir -p Testing/Temporary
  mkdir -p "$TEST_LOG_DIR"

  log "Starting lint build"
  set +e
  time (
    set -e
    $cmake_cmd_line "$YB_SRC_ROOT"
    make lint
  ) 2>&1 | tee "$TEST_LOG_DIR"/lint.log
  exit_code=$?
  set -e
  log "Lint build finished (see timing information above)"
  exit $exit_code
elif [[ $SKIP_CPP_MAKE == "0" ]]; then
  log "Running CMake with CMAKE_BUILD_TYPE set to $cmake_build_type"
  time $cmake_cmd_line "$YB_SRC_ROOT"
  log "Finished running CMake with build type $BUILD_TYPE (see timing information above)"
fi

# Only enable test core dumps for certain build types.
if [ "$BUILD_TYPE" != "asan" ]; then
  # TODO: actually make this take effect. The issue is that we might not be able to set ulimit
  # unless the OS configuration enables us to.
  export YB_TEST_ULIMIT_CORE=unlimited
fi

NUM_PROCS=$(getconf _NPROCESSORS_ONLN)

# Cap the number of parallel tests to run at $MAX_NUM_PARALLEL_TESTS
if [ "$NUM_PROCS" -gt "$MAX_NUM_PARALLEL_TESTS" ]; then
  NUM_PARALLEL_TESTS=$MAX_NUM_PARALLEL_TESTS
else
  NUM_PARALLEL_TESTS=$NUM_PROCS
fi

declare -i EXIT_STATUS=0

set +e
if [[ -d /tmp/yb-port-locks ]]; then
  # Allow other users to also run minicluster tests on this machine.
  chmod a+rwx /tmp/yb-port-locks
fi
set -e

if [[ $BUILD_CPP == "1" ]]; then
  echo
  echo Building C++ code.
  echo ------------------------------------------------------------
  if [[ $SKIP_CPP_MAKE == "0" ]]; then
    time make -j$NUM_PROCS $EXTRA_MAKE_ARGS 2>&1 | filter_boring_cpp_build_output
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      log "C++ build failed!"
      # TODO: perhaps we shouldn't even try to run C++ tests in this case?
      EXIT_STATUS=1
    fi

    log "Finished building C++ code (see timing information above)"
  else
    log "Skipped building C++ code, only running tests"
  fi

  if [[ -h $LATEST_BUILD_LINK ]]; then
    # This helps prevent Jenkins from showing every test twice in test results.
    unlink "$LATEST_BUILD_LINK"
  fi

  # -----------------------------------------------------------------------------------------------
  # Test package creation (i.e. relocating all the necessary libraries) right after the build.
  # This only works on Linux builds using Linuxbrew.

  if using_linuxbrew; then
    packaged_dest_dir=${BUILD_ROOT}__packaged
    rm -rf "$packaged_dest_dir"
    log "Testing creating a distribution in '$packaged_dest_dir'"
    python/yb/library_packager.py \
      --build-dir "$BUILD_ROOT" \
      --dest-dir "$packaged_dest_dir"
  fi

  # -----------------------------------------------------------------------------------------------

  # If compilation succeeds, try to run all remaining steps despite any failures.
  set +e

  # Run tests
  export GTEST_OUTPUT="xml:$TEST_LOG_DIR/" # Enable JUnit-compatible XML output.

  FAILURES=""

  log "Starting ctest"
  set +e
  time (
    set -x
    time ctest -j$NUM_PARALLEL_TESTS $EXTRA_TEST_FLAGS --output-log "$CTEST_FULL_OUTPUT_PATH" \
      --output-on-failure 2>&1 | tee "$CTEST_OUTPUT_PATH"
  )
  if [ $? -ne 0 ]; then
    EXIT_STATUS=1
    FAILURES="$FAILURES"$'C++ tests failed\n'
  fi
  set -e
  log "Finished running ctest (see timing information above)"

  if [ "$DO_COVERAGE" == "1" ]; then
    echo
    echo Generating coverage report...
    echo ------------------------------------------------------------
    if ! $YB_SRC_ROOT/thirdparty/gcovr-3.0/scripts/gcovr -r $YB_SRC_ROOT --xml \
        > $BUILD_ROOT/coverage.xml ; then
      EXIT_STATUS=1
      FAILURES="$FAILURES"$'Coverage report failed\n'
    fi
  fi

fi

if [[ $BUILD_JAVA == "1" ]]; then
  # Disk usage might have changed after the C++ build.
  show_disk_usage

  echo
  echo Building and testing java...
  echo ------------------------------------------------------------
  # Make sure we use JDK7
  export JAVA_HOME=$JAVA7_HOME
  export PATH=$JAVA_HOME/bin:$PATH
  pushd $YB_SRC_ROOT/java
  export TSAN_OPTIONS="$TSAN_OPTIONS suppressions=$YB_SRC_DIR/build-support/tsan-suppressions.txt \
    history_size=7"
  VALIDATE_CSD_FLAG=""
  if [ "$VALIDATE_CSD" == "1" ]; then
    VALIDATE_CSD_FLAG="-PvalidateCSD"
  fi
  if ! build_yb_java_code_with_retries \
      $MVN_FLAGS -PbuildCSD \
      $VALIDATE_CSD_FLAG \
      --fail-never \
      -DbinDir="$BUILD_ROOT"/bin \
      -Dsurefire.rerunFailingTestsCount=3 \
      -Dfailsafe.rerunFailingTestsCount=3 \
      clean verify 2>&1
  then
    EXIT_STATUS=1
    FAILURES="$FAILURES"$'Java build/test failed\n'
  fi
  popd
fi


if [[ $BUILD_PYTHON == "1" ]]; then
  show_disk_usage

  echo
  echo Building and testing python.
  echo ------------------------------------------------------------

  # Failing to compile the Python client should result in a build failure
  set -e
  export YB_HOME=$YB_SRC_ROOT
  export YB_BUILD=$BUILD_ROOT
  pushd $YB_SRC_ROOT/python

  # Create a sane test environment
  rm -Rf "$YB_BUILD/py_env"
  virtualenv $YB_BUILD/py_env
  source $YB_BUILD/py_env/bin/activate
  pip install --upgrade pip
  CC=$CLANG CXX=$CLANG++ pip install --disable-pip-version-check -r requirements.txt

  # Delete old Cython extensions to force them to be rebuilt.
  rm -Rf build kudu_python.egg-info kudu/*.so

  # Assuming we run this script from base dir
  CC=$CLANG CXX=$CLANG++ python setup.py build_ext
  set +e
  if ! python setup.py test \
      --addopts="kudu --junit-xml=$YB_BUILD/test-logs/python_client.xml" \
      2> $YB_BUILD/test-logs/python_client.log ; then
    EXIT_STATUS=1
    FAILURES="$FAILURES"$'Python tests failed\n'
  fi
  popd
fi

set -e

if [[ -n $FAILURES ]]; then
  echo Failure summary
  echo ------------------------------------------------------------
  echo $FAILURES
fi

exit $EXIT_STATUS
