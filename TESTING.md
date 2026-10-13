# Testing Harness for mpv Lua Scripts

Run mpv Lua scripts under luajit without mpv. No mpv required.

## The core trick

`require 'fake_mp'` sets the global `mp` object **before** your script loads.
Your real code then runs unmodified under a standalone Lua interpreter.

```lua
package.path = './your_script/?.lua;./tests/?.lua;' .. package.path
require 'fake_mp'        -- sets global mp, pre-registers mp.utils / mp.options
require 'main'           -- your real script, runs against the fake mp
```

## fake_mp.lua

Test double for the mpv Lua API. Must provide everything your script touches.

### The fake object

```lua
local fake = {
    commands = {},           -- recorded commandv calls
    props = {},              -- property store
    observers = {},          -- property observers
    script_messages = {},    -- registered script message handlers
    events = {},             -- registered event handlers
    timeouts = {},           -- registered timeouts
}
```

### Required APIs

| API | Behavior |
|-----|----------|
| `mp.commandv(...)` | `table.insert(fake.commands, {...})` — record, don't dispatch |
| `mp.get_property(name)` | `return fake.props[name]` |
| `mp.set_property(name, val)` | `fake.props[name] = val` |
| `mp.get_property_native(name)` | Same as get_property |
| `mp.set_property_native(name, val)` | Same as set_property |
| `mp.get_property_number(name)` | `type(v) == 'number' and v or nil` |
| `mp.set_property_number(name, val)` | Same as set_property |
| `mp.observe_property(prop, mode, fn)` | `fake.observers[prop] = fn` |
| `mp.register_script_message(name, fn)` | `fake.script_messages[name] = fn` |
| `mp.unregister_script_message(name)` | `fake.script_messages[name] = nil` |
| `mp.register_event(name, fn)` | `fake.events[name] = fn` |
| `mp.add_timeout(s, fn)` | Store `{fn=fn, timer={killed=false}}` in `fake.timeouts` |
| `mp.get_script_name()` | Return your script name (e.g. `'ucm'`) |
| `mp.msg.info/warn/error/debug` | Print or no-op |

### mp.utils sub-module

Pre-register as `package.loaded['mp.utils']` so `require 'mp.utils'` resolves:

```lua
local mp_utils = {}
function mp_utils.parse_json(str)    -- recursive-descent JSON decoder
function mp_utils.format_json(val)   -- JSON encoder with indentation
function mp_utils.to_string(val)     -- tostring(val)
```

**JSON null gotcha:** Real mpv's `parse_json` drops `null` values (indistinguishable
from omitted fields). If your script needs to distinguish them, map `null` to a
sentinel string before parsing, then coerce to `nil` later.

### mp.options sub-module

Pre-register as `package.loaded['mp.options']`:

```lua
local mp_options = {}
function mp_options.read_options(opts, name)
    -- Tests supply their own options; this is a no-op or reads from a test config
end
```

### Timers

Don't auto-fire. Store them, let tests call `t.fn()` manually to simulate time:

```lua
-- In the test:
for _, t in ipairs(mp.timeouts) do
    if not t.timer.killed then t.fn() end
end
```

### Keybindings

No-op stubs (tests usually don't exercise keybinding registration):

```lua
function fake.remove_key_binding() end
function fake.add_forced_key_binding() end
```

## Golden file testing

The most reliable pattern for mpv scripts: capture the output your script sends
to its IPC target, compare against a baseline file.

### 1. Build a fake IPC target

Model the script that receives your output. Record what it would receive:

```lua
local fake = {
    buttons = {},   -- name -> latest json
    order = {},     -- first-seen order
    count = 0,
}

function fake:set_button(name, json)
    self.count = self.count + 1
    if not self.buttons[name] then
        table.insert(self.order, name)
    end
    self.buttons[name] = json
end

function fake:get_all_buttons()
    local result = {}
    for _, name in ipairs(self.order) do
        table.insert(result, { name = name, json = self.buttons[name] })
    end
    return result
end

-- Convert to a stable baseline string (sorted keys, one line per item)
function fake:to_baseline()
    local lines = {}
    for _, btn in ipairs(self:get_all_buttons()) do
        local parsed = require('mp.utils').parse_json(btn.json)
        local compact = self:encode_sorted(parsed)  -- sort keys for stability
        table.insert(lines, btn.name .. '\t' .. compact)
    end
    return table.concat(lines, '\n')
end

-- Compare against baseline; return (ok, diff_lines)
function fake:compare(baseline)
    -- parse baseline, diff against current state, return list of differences
end

return fake
```

### 2. Write the integration test

```lua
package.path = './your_script/?.lua;./tests/?.lua;' .. package.path
require 'fake_mp'
local fake_mp = mp
local fake_target = require 'fake_target'  -- your IPC fake

-- Load your real config
local f = io.open('path/to/your.conf', 'r')
local content = f:read('*a')
f:close()

-- Parse into an options table (however your script reads config)
local options = {}
-- ... parse lines ...

-- Override read_options
mp.options.read_options = function(opts, _name)
    for k, v in pairs(options) do opts[k] = v end
end

-- Run the real script
require 'main'

-- Extract output from fake_mp.commands
for _, cmd in ipairs(fake_mp.commands) do
    if cmd[1] == 'script-message-to' and cmd[2] == 'your_target' and cmd[3] == 'set-something' then
        fake_target:set_something(cmd[4], cmd[5])
    end
end

-- Handle --update flag (regenerate baseline)
if arg[1] == '--update' then
    local out = io.open('tests/baseline.txt', 'w')
    out:write(fake_target:to_baseline())
    out:close()
    print('Baseline updated')
    os.exit(0)
end

-- Compare against baseline
local baseline = io.open('tests/baseline.txt'):read('*a')
local ok, diff = fake_target:compare(baseline)
if ok then
    print('PASS')
else
    print('FAIL:')
    for _, line in ipairs(diff) do print('  ' .. line) end
    os.exit(1)
end
```

### 3. Run

```bash
luajit tests/test_full.lua              # compare against baseline
luajit tests/test_full.lua --update     # regenerate baseline
```

## Simulating IPC interactions

If your script receives script messages from other scripts, call the registered
handlers directly:

```lua
-- Simulate an external script sending a message
mp.script_messages['some-message'](args...)

-- Simulate a property change
if mp.observers['some-prop'] then
    mp.observers['some-prop'](old_value, new_value)
end

-- Simulate a timer firing
for _, t in ipairs(mp.timeouts) do
    if not t.timer.killed then t.fn() end
end
```

## State cycling / multi-state verification

If your script has multiple states (e.g. cycling through button layouts),
verify each state produces different output:

```lua
local function snapshot()
    -- extract from fake_mp.commands into fake_target
    -- return fake_target:to_baseline()
end

local s1 = snapshot()
mp.script_messages['cycle']()
local s2 = snapshot()
mp.script_messages['cycle']()
local s3 = snapshot()

assert(s1 ~= s2, 'state 1 and 2 identical')
assert(s2 ~= s3, 'state 2 and 3 identical')
```

This catches bugs where a state change doesn't actually change the output.

## What to test

| Type | What | How |
|------|------|-----|
| Init | Script loads, sends initial output | Run `require 'main'`, capture commands |
| IPC in | External script sends a message | Call `mp.script_messages[name](...)` |
| Property change | mpv property changes | Call `mp.observers[prop](old, new)` |
| Timer | Delayed action fires | Call `t.fn()` |
| State cycling | Multiple states produce different output | Cycle + snapshot + assert inequality |
| Edge cases | Empty config, missing fields, null values | Vary the options table |

## What NOT to test

- Keybinding registration (mpv-specific, no-op in fake)
- Actual property observation timing (fake doesn't dispatch)
- Real mpv command execution (fake records, doesn't run)

## Adapting to a new repo

1. Copy `fake_mp.lua` (generic, works for any mpv script)
2. Build a fake for your IPC target (model the receiving script)
3. Write an integration test: load config, run script, capture, compare baseline
4. Add unit tests for pure functions you want to verify in isolation
5. Add state-cycling tests if your script has multiple visual states

The entire harness is ~200 lines of Lua. No frameworks, no fixtures, no mpv.
