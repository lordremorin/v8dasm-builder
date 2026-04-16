#!/bin/bash
# Apply V8 source modifications to enable bytecode disassembly output.
# Targeted at V8 9.4.146.24 — file paths and APIs may differ for other versions.
#
# Usage: ./apply-v8-patches.sh /path/to/v8/v8
set -euo pipefail

V8_SRC="${1:?Usage: $0 /path/to/v8/v8}"

echo "=== Applying V8 disassembly patches to ${V8_SRC} ==="

###############################################################################
# 1. Print function disassembly after deserialization (code-serializer.cc)
###############################################################################
# V8 <= 9.x: src/snapshot/code-serializer.cc
# V8 >= 10.x: src/codegen/code-serializer.cc
CODE_SER=""
for candidate in \
    "${V8_SRC}/src/snapshot/code-serializer.cc" \
    "${V8_SRC}/src/codegen/code-serializer.cc"; do
    if [ -f "$candidate" ]; then
        CODE_SER="$candidate"
        break
    fi
done
if [ -z "$CODE_SER" ]; then
    echo "ERROR: code-serializer.cc not found in src/snapshot/ or src/codegen/. Check V8 source path."
    echo "  Searched: ${V8_SRC}/src/snapshot/code-serializer.cc"
    echo "  Searched: ${V8_SRC}/src/codegen/code-serializer.cc"
    exit 1
fi
echo "  Found code-serializer.cc at: $CODE_SER"

# Insert disassembly code after successful deserialization.
# We look for the pattern where maybe_result is converted to result and insert after it.
# In V8 9.4, the line is typically:  Handle<SharedFunctionInfo> result;
# followed by:  if (!maybe_result.ToHandle(&result)) { ... }
# We insert after the closing brace of the error-handling block.
if grep -q "v8dasm patch" "$CODE_SER"; then
    echo "  code-serializer.cc: already patched, skipping."
else
    # Strategy: insert after "LOG(isolate, CodeLinePosInfoRecordEvent" block or
    # after "if (FLAG_profile_deserialization)" block in CodeSerializer::Deserialize.
    # Fallback: insert before the final "return result;" in Deserialize function.
    # We use a safe anchor: the line "return scope.CloseAndEscape(result);" or "return result;"
    # at the end of CodeSerializer::Deserialize.
    # Detect whether GetBytecodeArray needs isolate parameter (V8 >= 9.1)
    if grep -q 'GetBytecodeArray(IsolateT\*\|GetBytecodeArray(Isolate' "${V8_SRC}/src/objects/shared-function-info-inl.h" 2>/dev/null; then
        GET_BCA="GetBytecodeArray(isolate)"
        echo "  Detected: GetBytecodeArray requires isolate parameter"
    else
        GET_BCA="GetBytecodeArray()"
        echo "  Detected: GetBytecodeArray takes no parameters"
    fi

    if grep -q "return scope.CloseAndEscape(result);" "$CODE_SER"; then
        sed -i "/return scope.CloseAndEscape(result);/i\\  // --- v8dasm patch: print disassembly after deserialization ---\n  result->${GET_BCA}.Disassemble(std::cout);\n  std::cout << std::flush;\n  // --- end v8dasm patch ---" "$CODE_SER"
        echo "  code-serializer.cc: patched (CloseAndEscape path)."
    elif grep -q "return result;" "$CODE_SER"; then
        # Patch the last "return result;" in the file (inside Deserialize)
        tac "$CODE_SER" | sed "0,/return result;/{s/return result;/\/\/ --- end v8dasm patch ---\n  std::cout << std::flush;\n  result->${GET_BCA}.Disassemble(std::cout);\n  \/\/ --- v8dasm patch: print disassembly after deserialization ---\n  return result;/}" | tac > "${CODE_SER}.tmp" && mv "${CODE_SER}.tmp" "$CODE_SER"
        echo "  code-serializer.cc: patched (return result path)."
    else
        echo "  WARNING: Could not find insertion point in code-serializer.cc"
        echo "  You may need to manually add the following after deserialization succeeds:"
        echo '    result->GetBytecodeArray().Disassemble(std::cout);'
        echo '    std::cout << std::flush;'
    fi
    # Ensure <iostream> is included
    if ! grep -q '#include <iostream>' "$CODE_SER"; then
        sed -i '1s/^/#include <iostream>\n/' "$CODE_SER"
    fi
fi

###############################################################################
# 2. Print disassembly in SharedFunctionInfoPrint (objects-printer.cc)
###############################################################################
# In V8 9.4, this file is at src/diagnostics/objects-printer.cc
OBJ_PRINTER="${V8_SRC}/src/diagnostics/objects-printer.cc"
if [ ! -f "$OBJ_PRINTER" ]; then
    # Fallback for older versions
    OBJ_PRINTER="${V8_SRC}/src/objects/objects-printer.cc"
fi
if [ ! -f "$OBJ_PRINTER" ]; then
    echo "  WARNING: objects-printer.cc not found, skipping patch 2."
else
    if grep -q "SharedFunctionInfoDisassembly" "$OBJ_PRINTER"; then
        echo "  objects-printer.cc: already patched, skipping."
    else
        # Find the SharedFunctionInfoPrint function and insert before its last "os << "\\n";"
        # We use a Python helper for this more complex patch.
        python3 - "$OBJ_PRINTER" <<'PYEOF'
import sys, re, os

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Find SharedFunctionInfoPrint function body
pattern = r'(void SharedFunctionInfo::SharedFunctionInfoPrint\(.*?\{)'
match = re.search(pattern, content, re.DOTALL)
if not match:
    print("  WARNING: SharedFunctionInfoPrint not found in objects-printer.cc")
    print("  You may need to manually add disassembly code.")
    sys.exit(0)

start = match.start()
# Find the closing of the function (matching braces)
brace_count = 0
func_end = start
for i in range(match.end() - 1, len(content)):
    if content[i] == '{':
        brace_count += 1
    elif content[i] == '}':
        brace_count -= 1
        if brace_count == 0:
            func_end = i
            break

# Find the last "os <<" before func_end and insert before it
func_body = content[start:func_end]
last_os = func_body.rfind('os << "\\n"')
if last_os == -1:
    last_os = func_body.rfind('os <<')

if last_os == -1:
    print("  WARNING: Could not find insertion point in SharedFunctionInfoPrint")
    sys.exit(0)

insert_pos = start + last_os

# Detect if GetBytecodeArray needs isolate (V8 >= 9.1)
import glob, subprocess
needs_isolate = False
# Check via grep from the V8 source root
v8_src_root = os.path.dirname(filepath)
# Walk up to find src/objects/
while v8_src_root and not os.path.isdir(os.path.join(v8_src_root, 'src', 'objects')):
    v8_src_root = os.path.dirname(v8_src_root)
if v8_src_root:
    grep_result = subprocess.run(
        ['grep', '-r', 'GetBytecodeArray(Isolate', os.path.join(v8_src_root, 'src', 'objects')],
        capture_output=True, text=True)
    if 'GetBytecodeArray(Isolate' in grep_result.stdout:
        needs_isolate = True

if needs_isolate:
    get_bca = 'this->GetBytecodeArray(GetIsolateFromWritableObject(*this))'
    print("  Detected: GetBytecodeArray requires isolate parameter")
else:
    get_bca = 'this->GetBytecodeArray()'
    print("  Detected: GetBytecodeArray takes no parameters")

patch = f'''os << "\\n; #region SharedFunctionInfoDisassembly\\n";
  if (this->HasBytecodeArray()) {{
    {get_bca}.Disassemble(os);
    os << std::flush;
  }}
  os << "; #endregion";
  '''

content = content[:insert_pos] + patch + content[insert_pos:]
with open(filepath, 'w') as f:
    f.write(content)
print("  objects-printer.cc: patched SharedFunctionInfoPrint.")
PYEOF
    fi
fi

###############################################################################
# 3. Print object literal details + fixed array elements (objects.cc)
###############################################################################
# In V8 9.4, HeapObjectShortPrint is in src/objects/objects.cc
OBJECTS_CC="${V8_SRC}/src/objects/objects.cc"
if [ ! -f "$OBJECTS_CC" ]; then
    OBJECTS_CC="${V8_SRC}/src/objects/objects.cc"
fi
if [ ! -f "$OBJECTS_CC" ]; then
    echo "  WARNING: objects.cc not found, skipping patches 3 and 4."
else
    if grep -q "ObjectBoilerplateDescriptionPrint" "$OBJECTS_CC" && grep -q "#region ObjectBoilerplateDescription" "$OBJECTS_CC"; then
        echo "  objects.cc: ObjectBoilerplateDescription already patched, skipping."
    else
        python3 - "$OBJECTS_CC" <<'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

modified = False

# Patch OBJECT_BOILERPLATE_DESCRIPTION_TYPE case
old_pattern = 'case OBJECT_BOILERPLATE_DESCRIPTION_TYPE:'
if old_pattern in content and '#region ObjectBoilerplateDescription' not in content:
    # Find the case and replace its body up to the next break;
    import re
    pattern = r'(case OBJECT_BOILERPLATE_DESCRIPTION_TYPE:.*?)(break;)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        new_case = '''case OBJECT_BOILERPLATE_DESCRIPTION_TYPE: {
      int len = FixedArray::cast(*this).length();
      os << "<ObjectBoilerplateDescription[" << len << "]>";
      if (len) {
        os << "\\n; #region ObjectBoilerplateDescription\\n";
        ObjectBoilerplateDescription::cast(*this).ObjectBoilerplateDescriptionPrint(os);
        os << "; #endregion";
      }
      break;
    }'''
        content = content[:match.start()] + new_case + content[match.end():]
        modified = True
        print("  objects.cc: patched OBJECT_BOILERPLATE_DESCRIPTION_TYPE.")

# Patch FIXED_ARRAY_TYPE case
old_pattern2 = 'case FIXED_ARRAY_TYPE:'
if old_pattern2 in content and '#region FixedArray' not in content:
    import re
    pattern = r'(case FIXED_ARRAY_TYPE:.*?)(break;)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        new_case = '''case FIXED_ARRAY_TYPE: {
      int len = FixedArray::cast(*this).length();
      os << "<FixedArray[" << len << "]>";
      if (len) {
        os << "\\n; #region FixedArray\\n";
        FixedArray::cast(*this).FixedArrayPrint(os);
        os << "; #endregion";
      }
      break;
    }'''
        content = content[:match.start()] + new_case + content[match.end():]
        modified = True
        print("  objects.cc: patched FIXED_ARRAY_TYPE.")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
elif '#region ObjectBoilerplateDescription' in content:
    print("  objects.cc: already patched.")
else:
    print("  WARNING: Could not find expected patterns in objects.cc")
    print("  You may need to manually modify HeapObjectShortPrint.")
PYEOF
    fi
fi

echo "=== Patching complete ==="
echo ""
echo "NOTE: If any patches failed, you may need to apply them manually."
echo "The V8 API may differ slightly for your version. Check:"
echo "  - GetBytecodeArray() vs GetBytecodeArray(isolate)"
echo "  - HasBytecodeArray() vs HasBytecodeArray(isolate)"
echo "  - File locations may vary between V8 versions."
