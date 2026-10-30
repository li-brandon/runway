#!/bin/sh
# Fails if any call to `.minimumScaleFactor(...)` in Runway/ passes anything other than exactly
# `TextScaling.minimumFactor`, so text wraps rather than shrinking past the shared floor. Literals
# like 0.5 and other expressions, even ones that use the constant, are violations.
#
# Calls may span lines. Comments and string contents are ignored. TextScaling.swift, which owns
# the floor, is exempt.
#
# Prints file:line for each violation. Exits 0 if clean, 1 on violations, 2 if the check can't run.

cd "$(dirname "$0")/.." || exit 2
if [ ! -d Runway ]; then
  echo "lint-scale-factor: Runway/ not found" >&2
  exit 2
fi

violations="$(
  find Runway -type f -name '*.swift' ! -path Runway/Views/TextScaling.swift -exec awk '
    function report() {
      print file ":" call_line ": minimumScaleFactor must be passed TextScaling.minimumFactor"
    }

    # Finishes a call left open by the end of the previous file.
    function reset_file() {
      if (open) report()
      open = 0
      comments = 0
      multiline = 0
      file = FILENAME
    }

    # Returns the line without comments and string contents, tracking both across lines.
    function code_only(text,    out, i, c, two) {
      out = ""
      i = 1
      while (i <= length(text)) {
        c = substr(text, i, 1)
        two = substr(text, i, 2)
        if (comments > 0) {
          if (two == "/*") { comments++; i += 2 }
          else if (two == "*/") { comments--; i += 2 }
          else i++
        } else if (multiline) {
          if (c == "\\") i += 2
          else if (substr(text, i, 3) == "\"\"\"") { multiline = 0; out = out "\"\""; i += 3 }
          else i++
        } else if (two == "//") {
          break
        } else if (two == "/*") {
          comments = 1
          i += 2
        } else if (substr(text, i, 3) == "\"\"\"") {
          multiline = 1
          i += 3
        } else if (c == "\"") {
          i++
          while (i <= length(text) && substr(text, i, 1) != "\"") {
            i += (substr(text, i, 1) == "\\") ? 2 : 1
          }
          i++
          out = out "\"\""
        } else {
          out = out c
          i++
        }
      }
      return out
    }

    FNR == 1 { reset_file() }

    {
      line = code_only($0)
      while (line != "") {
        if (open) {
          # Collects arguments up to the closing parenthesis, which may be on a later line.
          i = 1
          while (i <= length(line) && open) {
            c = substr(line, i, 1)
            if (c == "(") depth++
            else if (c == ")") depth--
            if (depth == 0) open = 0
            else args = args c
            i++
          }
          if (open) break
          line = substr(line, i)
          gsub(/[ \t\r]/, "", args)
          if (args != "TextScaling.minimumFactor") report()
        } else {
          # The leading space stands in for the start of the line.
          padded = " " line
          if (!match(padded, /[^A-Za-z0-9_]minimumScaleFactor[ \t]*[(]/)) break
          line = substr(padded, RSTART + RLENGTH)
          call_line = FNR
          open = 1
          depth = 1
          args = ""
        }
      }
    }

    END { if (open) report() }
  ' {} +
)" || {
  echo "lint-scale-factor: could not scan Runway/" >&2
  exit 2
}

if [ -n "$violations" ]; then
  printf '%s\n' "$violations" | sort -t : -k 1,1 -k 2,2n
  echo "Use .minimumScaleFactor(TextScaling.minimumFactor); see Runway/Views/TextScaling.swift." >&2
  exit 1
fi
