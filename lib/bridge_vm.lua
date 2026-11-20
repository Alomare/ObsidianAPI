-- A LuaJIT 2.0 bytecode interpreter in Lua, for the Memory Bridge. The retail game loads no new code
-- at runtime: a mod's loadstring answers nothing, source or bytecode, and dofile looks a name up among
-- the game's resources. So the bridge runs the bytecode itself, instruction by instruction, against the
-- game's real tables and functions: metamethods, game calls and errors behave as in compiled code, and
-- a function the code makes is a real Lua function the game can call (a hook, a frame function).
--
-- The tool compiles with a real LuaJIT 2.0, so parsing, scoping and upvalues are the compiler's. The
-- opcode numbers differ between LuaJIT 2.0 builds (ITERN and ISNEXT came late), so the tool sends the
-- names of its compiler's opcodes (bcnames of jit/vmdef.lua) with each request.
--
-- Formats: lj_bcdump.h, lj_bcread.c and lj_bc.h of LuaJIT 2.0.
local M = { located = {}, located_count = 0, trace = {} }

M.DEFAULT_NAMES = "ISLT  ISGE  ISLE  ISGT  ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC  ISFC  IST   ISF   MOV   NOT   UNM   LEN   ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV MODVV POW   CAT   KSTR  KCDATAKSHORTKNUM  KPRI  KNIL  UGET  USETV USETS USETN USETP UCLO  FNEW  TNEW  TDUP  GGET  GSET  TGETV TGETS TGETB TSETV TSETS TSETB TSETM CALLM CALL  CALLMTCALLT ITERC ITERN VARG  ISNEXTRETM  RET   RET0  RET1  FORI  JFORI FORL  IFORL JFORL ITERL IITERLJITERLLOOP  ILOOP JLOOP JMP   FUNCF IFUNCFJFUNCFFUNCV IFUNCVJFUNCVFUNCC FUNCCW"

local byte, sub, floor, select, unpack, error, type, pcall = string.byte, string.sub, math.floor, select, unpack, error, type, pcall
local host_error = error

-- Opcode number to name, from a bcnames string (six characters a name).
local maps = {}
function M.opcodes(names)
	names = names or M.DEFAULT_NAMES
	local map = maps[names]
	if map then return map end
	map = {}
	for i = 0, floor(#names / 6) - 1 do
		map[i] = (string.gsub(sub(names, i * 6 + 1, i * 6 + 6), " +$", ""))
	end
	maps[names] = map
	return map
end

-- Reading -------------------------------------------------------------------------------------------------

local function reader(s) return { s = s, p = 1 } end

local function u8(r)
	local b = byte(r.s, r.p)
	if not b then host_error("bytecode: cut short", 0) end
	r.p = r.p + 1
	return b
end

local function uleb(r)
	local v, shift = 0, 1
	while true do
		local b = u8(r)
		v = v + (b % 128) * shift
		if b < 128 then return v end
		shift = shift * 128
	end
end

-- uleb128_33: the first byte gives up its lowest bit (in knum, whether the constant is a double).
local function uleb33(r)
	local b = u8(r)
	local v = floor(b / 2)
	if v >= 0x40 then
		v = v % 0x40
		local shift = 64
		repeat
			b = u8(r)
			v = v + (b % 128) * shift
			shift = shift * 128
		until b < 128
	end
	return v
end

-- The double with these two 32 bit halves.
function M.double(lo, hi)
	local sign = hi >= 0x80000000 and -1 or 1
	local e = floor(hi / 0x100000) % 0x800
	local m = (hi % 0x100000) * 4294967296 + lo
	if e == 0x7ff then
		if m == 0 then return sign * math.huge end
		return 0 / 0
	end
	if e == 0 then return sign * m * 2 ^ -1074 end
	return sign * (1 + m / 4503599627370496) * 2 ^ (e - 1023)
end

local function int32(v)
	if v >= 0x80000000 then return v - 0x100000000 end
	return v
end

local function ktabk(r)
	local tp = uleb(r)
	if tp >= 5 then
		local len = tp - 5
		local s = sub(r.s, r.p, r.p + len - 1)
		r.p = r.p + len
		return s
	elseif tp == 3 then
		return int32(uleb(r))
	elseif tp == 4 then
		local lo = uleb(r)
		return M.double(lo, uleb(r))
	elseif tp == 2 then
		return true
	elseif tp == 1 then
		return false
	end
	return nil
end

local function read_proto(r, stack, strip, chunk, ops)
	local p = { name = chunk }
	local flags = u8(r)
	p.vararg = (floor(flags / 2) % 2) == 1
	p.numparams = u8(r)
	u8(r) -- framesize
	local sizeuv = u8(r)
	local sizekgc, sizekn, sizebc = uleb(r), uleb(r), uleb(r) + 1
	local sizedbg, firstline, numline = 0, 0, 0
	if not strip then
		sizedbg = uleb(r)
		if sizedbg > 0 then
			firstline, numline = uleb(r), uleb(r)
		end
	end
	p.firstline = firstline
	-- Instructions 1 to sizebc - 1 (0, the function header, isn't dumped), split into parts.
	local OP, A, B, C, D = {}, {}, {}, {}, {}
	local s, at = r.s, r.p
	for i = 1, sizebc - 1 do
		local b0, b1, b2, b3 = byte(s, at, at + 3)
		if not b3 then host_error("bytecode: cut short", 0) end
		local name = ops[b0]
		if not name then host_error("bytecode: unknown opcode " .. b0, 0) end
		OP[i], A[i], C[i], B[i], D[i] = name, b1, b2, b3, b2 + b3 * 256
		at = at + 4
	end
	r.p = at
	p.OP, p.A, p.B, p.C, p.D, p.size = OP, A, B, C, D, sizebc - 1
	-- Upvalues: a slot of the parent's frame (local) or an upvalue of the parent.
	local uv = {}
	for i = 1, sizeuv do
		local lo, hi = u8(r), u8(r)
		local v = lo + hi * 256
		if v >= 0x8000 then
			uv[i] = { slot = v % 0x4000 }
		else
			uv[i] = { up = v % 0x4000 }
		end
	end
	p.uv = uv
	-- Object constants, numbered from the end: D in an instruction is sizekgc - 1 - the order read.
	local kgc = {}
	for j = 0, sizekgc - 1 do
		local tp = uleb(r)
		local v
		if tp >= 5 then
			local len = tp - 5
			v = sub(r.s, r.p, r.p + len - 1)
			r.p = r.p + len
		elseif tp == 0 then
			v = table.remove(stack)
			if not v then host_error("bytecode: a child prototype is missing", 0) end
		elseif tp == 1 then
			local narray, nhash = uleb(r), uleb(r)
			v = {}
			for i = 0, narray - 1 do
				local x = ktabk(r)
				if x ~= nil then v[i] = x end
			end
			for _ = 1, nhash do
				local k = ktabk(r)
				local x = ktabk(r)
				if k ~= nil then v[k] = x end
			end
		else
			host_error("bytecode: cdata constants (FFI) aren't supported", 0)
		end
		kgc[sizekgc - 1 - j] = v
	end
	p.kgc = kgc
	-- Number constants, numbered from 0. lo is kept: TSETM reads its index from the low half.
	local kn, kn_lo = {}, {}
	for i = 0, sizekn - 1 do
		local isnum = byte(r.s, r.p) % 2 == 1
		local lo = uleb33(r)
		if isnum then
			kn[i] = M.double(lo, uleb(r))
		else
			kn[i] = int32(lo)
		end
		kn_lo[i] = lo
	end
	p.kn, p.kn_lo = kn, kn_lo
	-- Line numbers, one per instruction, after the first line; then names, unread.
	if sizedbg > 0 then
		local start = r.p
		local n = numline < 256 and 1 or (numline < 65536 and 2 or 4)
		local lines = {}
		for i = 1, sizebc - 1 do
			local v, scale = 0, 1
			for _ = 1, n do
				v = v + u8(r) * scale
				scale = scale * 256
			end
			lines[i] = firstline + v
		end
		p.lines = lines
		r.p = start + sizedbg
	end
	return p
end

-- The prototypes of a bytecode dump; the main one last.
function M.parse(s, names)
	local ops = M.opcodes(names)
	local r = reader(s)
	if sub(s, 1, 3) ~= "\27LJ" then host_error("bytecode: not LuaJIT bytecode", 0) end
	r.p = 4
	local version = u8(r)
	if version ~= 1 then host_error("bytecode: version " .. version .. ", not LuaJIT 2.0", 0) end
	local flags = uleb(r)
	if flags % 2 == 1 then host_error("bytecode: big endian", 0) end
	if floor(flags / 4) % 2 == 1 then host_error("bytecode: uses the FFI", 0) end
	local strip = floor(flags / 2) % 2 == 1
	local chunk = "bridge"
	if not strip then
		local len = uleb(r)
		chunk = sub(s, r.p, r.p + len - 1)
		r.p = r.p + len
		chunk = string.gsub(chunk, "^[=@]", "")
	end
	local stack = {}
	while true do
		local len = uleb(r)
		if len == 0 then break end
		local start = r.p
		-- Read first: the prototype takes its children off the stack.
		local p = read_proto(r, stack, strip, chunk, ops)
		stack[#stack + 1] = p
		r.p = start + len
	end
	if #stack ~= 1 then host_error("bytecode: " .. #stack .. " prototypes left over", 0) end
	return stack[1]
end

-- Running ---------------------------------------------------------------------------------------------------

-- The prefix the host puts on an error raised in this file ("<chunk>:<line>: "), so that a message
-- about an operation of the code names the code's line instead.
local OWN = nil
do
	local _, sample = pcall(function() local t = nil; return t.x end)
	if type(sample) == "string" then OWN = string.match(sample, "^(.-):%-?%d+: ") end
end

local function plain(msg)
	if OWN and sub(msg, 1, #OWN + 1) == OWN .. ":" then
		local rest = string.match(msg, "^.-:%-?%d+: (.*)$")
		if rest then return rest end
	end
	return msg
end

local function mark(msg)
	if M.located_count > 2000 then M.located, M.located_count = {}, 0 end
	M.located[msg] = true
	M.located_count = M.located_count + 1
	return msg
end

local function where(f)
	local p = f.proto
	local line = p.lines and p.lines[f.pc]
	return p.name .. ":" .. (line and tostring(line) or "?")
end

-- A frame that ends in an error: the message gets the code's line once, and each frame adds a line to
-- M.trace on the way out.
local function locate(f, err)
	M.trace[#M.trace + 1] = where(f) .. ": in function <" .. f.proto.name .. ":" .. f.proto.firstline .. ">"
	if type(err) ~= "string" or M.located[err] then return err end
	return mark(where(f) .. ": " .. plain(err))
end

local function pack(...) return { n = select("#", ...), ... } end

local function get(cell)
	if cell.open then return cell.R[cell.i] end
	return cell.v
end

local function put(cell, v)
	if cell.open then cell.R[cell.i] = v else cell.v = v end
end

local function close(f, from)
	local open = f.open
	if not open then return end
	for slot, cell in pairs(open) do
		if slot >= from then
			cell.v, cell.open, cell.R = cell.R[slot], false, nil
			open[slot] = nil
		end
	end
end

local function pri(d)
	if d == 1 then return false end
	if d == 2 then return true end
	return nil
end

local closure

-- The instructions of one call, from f.pc on. Answers what the function returns.
local function loop(f)
	local p, R, cells, env = f.proto, f.R, f.cells, f.env
	local OP, A, B, C, D, kgc, kn = p.OP, p.A, p.B, p.C, p.D, p.kgc, p.kn
	local pc, mr = 1, 0
	while true do
		f.pc = pc
		local op, a = OP[pc], A[pc]
		pc = pc + 1
		if op == "MOV" then R[a] = R[D[pc - 1]]
		elseif op == "GGET" then R[a] = env[kgc[D[pc - 1]]]
		elseif op == "TGETS" then R[a] = R[B[pc - 1]][kgc[C[pc - 1]]]
		elseif op == "KSTR" then R[a] = kgc[D[pc - 1]]
		elseif op == "CALL" or op == "CALLM" then
			local i = pc - 1
			local fn, b = R[a], B[i]
			local last = op == "CALL" and a + C[i] - 1 or a + C[i] + mr
			if fn == host_error then
				-- error() raised here names the code's line, as it would compiled.
				local msg, level = R[a + 1], R[a + 2]
				if type(msg) == "string" and level ~= 0 then msg = mark(where(f) .. ": " .. msg) end
				host_error(msg, 0)
			end
			if b == 2 then
				R[a] = fn(unpack(R, a + 1, last))
			elseif b == 1 then
				fn(unpack(R, a + 1, last))
			else
				local res = pack(fn(unpack(R, a + 1, last)))
				if b == 0 then
					for k = 1, res.n do R[a + k - 1] = res[k] end
					mr = res.n
				else
					for k = 1, b - 1 do R[a + k - 1] = res[k] end
				end
			end
		elseif op == "KSHORT" then
			local d = D[pc - 1]
			R[a] = d >= 0x8000 and d - 0x10000 or d
		elseif op == "KNUM" then R[a] = kn[D[pc - 1]]
		elseif op == "KPRI" then R[a] = pri(D[pc - 1])
		elseif op == "KNIL" then for k = a, D[pc - 1] do R[k] = nil end
		elseif op == "UGET" then R[a] = get(cells[D[pc - 1] + 1])
		elseif op == "TGETV" then R[a] = R[B[pc - 1]][R[C[pc - 1]]]
		elseif op == "TGETB" then R[a] = R[B[pc - 1]][C[pc - 1]]
		elseif op == "TSETS" then R[B[pc - 1]][kgc[C[pc - 1]]] = R[a]
		elseif op == "TSETV" then R[B[pc - 1]][R[C[pc - 1]]] = R[a]
		elseif op == "TSETB" then R[B[pc - 1]][C[pc - 1]] = R[a]
		elseif op == "GSET" then env[kgc[D[pc - 1]]] = R[a]
		elseif op == "JMP" then pc = pc + D[pc - 1] - 0x8000
		elseif op == "LOOP" then -- a hint for the JIT
		-- Checks that a pairs() loop may use ITERN, then jumps to it; ITERN runs as ITERC here.
		elseif op == "ISNEXT" then pc = pc + D[pc - 1] - 0x8000
		elseif op == "RET0" then return
		elseif op == "RET1" then return R[a]
		elseif op == "RET" then return unpack(R, a, a + D[pc - 1] - 2)
		elseif op == "RETM" then return unpack(R, a, a + D[pc - 1] + mr - 1)
		elseif op == "CALLT" then
			local fn = R[a]
			if fn == host_error then
				local msg, level = R[a + 1], R[a + 2]
				if type(msg) == "string" and level ~= 0 then msg = mark(where(f) .. ": " .. msg) end
				host_error(msg, 0)
			end
			return fn(unpack(R, a + 1, a + D[pc - 1] - 1))
		elseif op == "CALLMT" then return R[a](unpack(R, a + 1, a + D[pc - 1] + mr))
		elseif op == "VARG" then
			local va, b = f.va, B[pc - 1]
			if b == 0 then
				for k = 1, va.n do R[a + k - 1] = va[k] end
				mr = va.n
			else
				for k = 1, b - 1 do R[a + k - 1] = va[k] end
			end
		elseif op == "ITERC" or op == "ITERN" then
			R[a], R[a + 1], R[a + 2] = R[a - 3], R[a - 2], R[a - 1]
			local b = B[pc - 1]
			local res = pack(R[a](R[a + 1], R[a + 2]))
			for k = 1, b - 1 do R[a + k - 1] = res[k] end
		elseif op == "ITERL" then
			if R[a] ~= nil then
				R[a - 1] = R[a]
				pc = pc + D[pc - 1] - 0x8000
			end
		elseif op == "FORI" then
			local start, stop, step = R[a], R[a + 1], R[a + 2]
			if type(start) ~= "number" then host_error("'for' initial value must be a number", 0) end
			if type(stop) ~= "number" then host_error("'for' limit must be a number", 0) end
			if type(step) ~= "number" then host_error("'for' step must be a number", 0) end
			if (step >= 0 and start <= stop) or (step < 0 and start >= stop) then
				R[a + 3] = start
			else
				pc = pc + D[pc - 1] - 0x8000
			end
		elseif op == "FORL" then
			local step = R[a + 2]
			local v = R[a] + step
			R[a] = v
			if (step >= 0 and v <= R[a + 1]) or (step < 0 and v >= R[a + 1]) then
				R[a + 3] = v
				pc = pc + D[pc - 1] - 0x8000
			end
		elseif op == "ISLT" or op == "ISGE" or op == "ISLE" or op == "ISGT" or op == "ISEQV" or op == "ISNEV"
			or op == "ISEQS" or op == "ISNES" or op == "ISEQN" or op == "ISNEN" or op == "ISEQP" or op == "ISNEP" then
			local x, d = R[a], D[pc - 1]
			local yes
			if op == "ISLT" then yes = x < R[d]
			elseif op == "ISGE" then yes = not (x < R[d])
			elseif op == "ISLE" then yes = x <= R[d]
			elseif op == "ISGT" then yes = not (x <= R[d])
			elseif op == "ISEQV" then yes = x == R[d]
			elseif op == "ISNEV" then yes = x ~= R[d]
			elseif op == "ISEQS" then yes = x == kgc[d]
			elseif op == "ISNES" then yes = x ~= kgc[d]
			elseif op == "ISEQN" then yes = x == kn[d]
			elseif op == "ISNEN" then yes = x ~= kn[d]
			elseif op == "ISEQP" then yes = x == pri(d)
			else yes = x ~= pri(d) end
			-- The next instruction is the jump to take.
			if yes then pc = pc + 1 + D[pc] - 0x8000 else pc = pc + 1 end
		elseif op == "ISTC" or op == "ISFC" or op == "IST" or op == "ISF" then
			local v = R[D[pc - 1]]
			local truthy = v ~= nil and v ~= false
			local yes = (op == "ISTC" or op == "IST") and truthy or ((op == "ISFC" or op == "ISF") and not truthy)
			if yes then
				if op == "ISTC" or op == "ISFC" then R[a] = v end
				pc = pc + 1 + D[pc] - 0x8000
			else
				pc = pc + 1
			end
		elseif op == "NOT" then R[a] = not R[D[pc - 1]]
		elseif op == "UNM" then R[a] = -R[D[pc - 1]]
		elseif op == "LEN" then R[a] = #R[D[pc - 1]]
		elseif op == "ADDVN" then R[a] = R[B[pc - 1]] + kn[C[pc - 1]]
		elseif op == "SUBVN" then R[a] = R[B[pc - 1]] - kn[C[pc - 1]]
		elseif op == "MULVN" then R[a] = R[B[pc - 1]] * kn[C[pc - 1]]
		elseif op == "DIVVN" then R[a] = R[B[pc - 1]] / kn[C[pc - 1]]
		elseif op == "MODVN" then R[a] = R[B[pc - 1]] % kn[C[pc - 1]]
		elseif op == "ADDNV" then R[a] = kn[C[pc - 1]] + R[B[pc - 1]]
		elseif op == "SUBNV" then R[a] = kn[C[pc - 1]] - R[B[pc - 1]]
		elseif op == "MULNV" then R[a] = kn[C[pc - 1]] * R[B[pc - 1]]
		elseif op == "DIVNV" then R[a] = kn[C[pc - 1]] / R[B[pc - 1]]
		elseif op == "MODNV" then R[a] = kn[C[pc - 1]] % R[B[pc - 1]]
		elseif op == "ADDVV" then R[a] = R[B[pc - 1]] + R[C[pc - 1]]
		elseif op == "SUBVV" then R[a] = R[B[pc - 1]] - R[C[pc - 1]]
		elseif op == "MULVV" then R[a] = R[B[pc - 1]] * R[C[pc - 1]]
		elseif op == "DIVVV" then R[a] = R[B[pc - 1]] / R[C[pc - 1]]
		elseif op == "MODVV" then R[a] = R[B[pc - 1]] % R[C[pc - 1]]
		elseif op == "POW" then R[a] = R[B[pc - 1]] ^ R[C[pc - 1]]
		elseif op == "CAT" then
			local b, c = B[pc - 1], C[pc - 1]
			local v = R[c]
			for k = c - 1, b, -1 do v = R[k] .. v end
			R[a] = v
		elseif op == "USETV" then put(cells[a + 1], R[D[pc - 1]])
		elseif op == "USETS" then put(cells[a + 1], kgc[D[pc - 1]])
		elseif op == "USETN" then put(cells[a + 1], kn[D[pc - 1]])
		elseif op == "USETP" then put(cells[a + 1], pri(D[pc - 1]))
		elseif op == "UCLO" then
			close(f, a)
			pc = pc + D[pc - 1] - 0x8000
		elseif op == "FNEW" then
			local child = kgc[D[pc - 1]]
			local list = {}
			for k, u in ipairs(child.uv) do
				if u.slot then
					local open = f.open
					if not open then
						open = {}
						f.open = open
					end
					local cell = open[u.slot]
					if not cell then
						cell = { open = true, R = R, i = u.slot }
						open[u.slot] = cell
					end
					list[k] = cell
				else
					list[k] = cells[u.up + 1]
				end
			end
			R[a] = closure(child, list, env)
		elseif op == "TNEW" then R[a] = {}
		elseif op == "TDUP" then
			local t = {}
			for k, v in pairs(kgc[D[pc - 1]]) do t[k] = v end
			R[a] = t
		elseif op == "TSETM" then
			local t, base = R[a - 1], p.kn_lo[D[pc - 1]]
			for k = 0, mr - 1 do t[base + k] = R[a + k] end
		else
			host_error("the bridge can't run " .. tostring(op), 0)
		end
	end
end

local function finish(f, ok, ...)
	close(f, 0)
	if ok then return ... end
	host_error(locate(f, (...)), 0)
end

local function run(p, cells, env, ...)
	local n = select("#", ...)
	local R = {}
	for i = 1, p.numparams do R[i - 1] = (select(i, ...)) end
	local f = { proto = p, R = R, cells = cells, env = env, pc = 1 }
	if p.vararg then
		local va = { n = n > p.numparams and n - p.numparams or 0 }
		for i = 1, va.n do va[i] = (select(p.numparams + i, ...)) end
		f.va = va
	end
	return finish(f, pcall(loop, f))
end

closure = function(p, cells, env)
	return function(...) return run(p, cells, env, ...) end
end

-- The main function of a bytecode dump, as a function of the host with `env` for its globals.
function M.load(code, env, names)
	local ok, main = pcall(M.parse, code, names)
	if not ok then return nil, main end
	return closure(main, {}, env)
end

-- Before a request: the trace of the last error starts empty.
function M.reset()
	M.trace = {}
end

return M
