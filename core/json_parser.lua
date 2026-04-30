-- ---------------------------------------------------------------------------
-- Tiny pure-Lua JSON decoder (subset).
--
-- Handles strings, numbers, bool, null, objects, arrays. No streaming;
-- input is a string. Used for parsing merged WarMap data files (~MB scale).
-- ---------------------------------------------------------------------------

local M = {}

local decode

local function skip_ws(s, i)
    while i <= #s do
        local c = s:byte(i)
        if c == 32 or c == 9 or c == 10 or c == 13 then
            i = i + 1
        else
            return i
        end
    end
    return i
end

local function parse_string(s, i)
    local j = i + 1
    local out = {}
    while j <= #s do
        local c = s:sub(j, j)
        if c == '"' then
            return table.concat(out), j + 1
        elseif c == '\\' then
            local nxt = s:sub(j + 1, j + 1)
            if     nxt == 'n' then out[#out+1] = '\n'
            elseif nxt == 't' then out[#out+1] = '\t'
            elseif nxt == 'r' then out[#out+1] = '\r'
            elseif nxt == 'b' then out[#out+1] = '\b'
            elseif nxt == 'f' then out[#out+1] = '\f'
            elseif nxt == '"' then out[#out+1] = '"'
            elseif nxt == '\\' then out[#out+1] = '\\'
            elseif nxt == '/' then out[#out+1] = '/'
            elseif nxt == 'u' then
                local hex = s:sub(j + 2, j + 5)
                local cp = tonumber(hex, 16) or 0
                if cp < 0x80 then
                    out[#out+1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out+1] = string.char(0xC0 + math.floor(cp / 0x40),
                                              0x80 + (cp % 0x40))
                else
                    out[#out+1] = string.char(0xE0 + math.floor(cp / 0x1000),
                                              0x80 + (math.floor(cp / 0x40) % 0x40),
                                              0x80 + (cp % 0x40))
                end
                j = j + 4
            else
                error('bad escape at ' .. tostring(j))
            end
            j = j + 2
        else
            out[#out+1] = c
            j = j + 1
        end
    end
    error('unterminated string')
end

local function parse_number(s, i)
    local j = i
    while j <= #s do
        local c = s:byte(j)
        if (c >= 48 and c <= 57) or c == 43 or c == 45 or c == 46
           or c == 69 or c == 101 then
            j = j + 1
        else
            break
        end
    end
    return tonumber(s:sub(i, j - 1)), j
end

local function parse_array(s, i)
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then return out, i + 1 end
    while true do
        local v
        v, i = decode(s, i)
        out[#out + 1] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ',' then i = skip_ws(s, i + 1)
        elseif c == ']' then return out, i + 1
        else error('expected , or ] at ' .. tostring(i)) end
    end
end

local function parse_object(s, i)
    local out = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then return out, i + 1 end
    while true do
        local k
        if s:sub(i, i) ~= '"' then error('expected string key at ' .. tostring(i)) end
        k, i = parse_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then error('expected : at ' .. tostring(i)) end
        i = skip_ws(s, i + 1)
        local v
        v, i = decode(s, i)
        out[k] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ',' then i = skip_ws(s, i + 1)
        elseif c == '}' then return out, i + 1
        else error('expected , or } at ' .. tostring(i)) end
    end
end

decode = function (s, i)
    i = skip_ws(s, i or 1)
    local c = s:sub(i, i)
    if c == '{' then return parse_object(s, i) end
    if c == '[' then return parse_array(s, i) end
    if c == '"' then return parse_string(s, i) end
    if c == 't' and s:sub(i, i + 3) == 'true'  then return true,  i + 4 end
    if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
    if c == 'n' and s:sub(i, i + 3) == 'null'  then return nil,   i + 4 end
    local n
    n, i = parse_number(s, i)
    if not n then error('bad value at ' .. tostring(i)) end
    return n, i
end

M.decode = function (s)
    local ok, result = pcall(function () return (decode(s, 1)) end)
    if ok then return result end
    return nil, tostring(result)
end

return M
