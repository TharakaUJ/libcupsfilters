#!/usr/bin/env bash
#
# Regression test for #166: cfFilterPWGToPDF() must fail the job cleanly when
# prepare_pdf_page() rejects a page, instead of calling the NULL
# doc->bit_function in convert_raster().
#
# The C harness (test-pwgtopdf-bad-colorspace.c) #includes the in-tree
# cupsfilters/pwgtopdf.c, writes a one-row 8-bit CIELab PWG page (a color
# space prepare_pdf_page() does not support) and runs the filter on it under
# AddressSanitizer.  Before the fix this was a SEGV; now the filter must
# return non-zero and log "Unable to start new PDF page".
#
# Skips (Automake exit 77) when AddressSanitizer is unavailable.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(cd "${ROOT}/.." && pwd)"
LIBTOOL="${BUILD_ROOT}/libtool"
CC="${CC:-cc}"
SAN_FLAGS="${SAN_FLAGS:--fsanitize=address -fno-omit-frame-pointer}"

# The compiler accepting -fsanitize=address is not enough: qemu-user builds
# can link the runtime but abort while initializing it.  Run a trivial probe so
# those emulated CI legs skip instead of reporting a product-code failure.
asan_probe="$(mktemp "${TMPDIR:-/tmp}/asan-probe.XXXXXX")"
if ! printf 'int main(void){return 0;}\n' \
       | "${CC}" ${SAN_FLAGS} -x c - -o "${asan_probe}" >/dev/null 2>&1 \
   || ! "${asan_probe}" >/dev/null 2>&1; then
  echo "AddressSanitizer not usable in this environment; skipping." >&2
  rm -f "${asan_probe}"
  exit 77
fi
rm -f "${asan_probe}"

if [[ ! -x "${LIBTOOL}" ]]; then
  echo "libtool helper not found at ${LIBTOOL}" >&2
  exit 99
fi

SRC="${ROOT}/test-pwgtopdf-bad-colorspace.c"
if [[ ! -f "${SRC}" ]]; then
  echo "test source not found: ${SRC}" >&2
  exit 99
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pwgtopdf-bad-colorspace.XXXXXX")"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

OBJ="${WORKDIR}/test-pwgtopdf-bad-colorspace.lo"
BIN="${WORKDIR}/test-pwgtopdf-bad-colorspace"
RUN_LOG="${WORKDIR}/run.log"

# Flags for pwgtopdf.c's own dependencies.  Fall back to cups3.
PKG_CFLAGS="$(pkg-config --cflags lcms2 pdfio cups 2>/dev/null \
              || pkg-config --cflags lcms2 pdfio cups3 2>/dev/null || true)"
PKG_LIBS="$(pkg-config --libs lcms2 pdfio cups 2>/dev/null \
            || pkg-config --libs lcms2 pdfio cups3 2>/dev/null || true)"

"${LIBTOOL}" --mode=compile --tag=CC "${CC}" -std=gnu11 -O0 \
  -D_GNU_SOURCE ${SAN_FLAGS} \
  -I"${BUILD_ROOT}" -I"${BUILD_ROOT}/cupsfilters" ${PKG_CFLAGS} \
  -c "${SRC}" -o "${OBJ}" >/dev/null

"${LIBTOOL}" --mode=link --tag=CC "${CC}" ${SAN_FLAGS} "${OBJ}" \
  "${BUILD_ROOT}/libcupsfilters.la" ${PKG_LIBS} -lm \
  -o "${BIN}" >/dev/null

ASAN_OPTS="${ASAN_OPTIONS:-detect_leaks=0,abort_on_error=0}"
set +e
"${LIBTOOL}" --mode=execute env \
  DYLD_LIBRARY_PATH="${BUILD_ROOT}/.libs${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}" \
  ASAN_OPTIONS="${ASAN_OPTS}" \
  "${BIN}" "${WORKDIR}/cielab-8bit.pwg" "${WORKDIR}/output.pdf" \
  >"${RUN_LOG}" 2>&1
STATUS=$?
set -e

if grep -q "AddressSanitizer" "${RUN_LOG}"; then
  cat "${RUN_LOG}" >&2
  echo "AddressSanitizer reported a memory error" >&2
  exit 1
fi

if [[ ${STATUS} -eq 0 ]]; then
  cat "${RUN_LOG}" >&2
  echo "pwgtopdf accepted a page with an unsupported color space" >&2
  exit 1
fi

if ! grep -q "Unable to start new PDF page" "${RUN_LOG}"; then
  cat "${RUN_LOG}" >&2
  echo "pwgtopdf did not reject the page cleanly" >&2
  exit 1
fi

exit 0
