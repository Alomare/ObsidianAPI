-- Screenshots: the game's picture, saved as a PNG or JPEG file. The engine has no call for it, so this
-- goes to Windows through LuaJIT's FFI, which the game's own scripts load (foundation/lua/util/noise.lua
-- sets HAS_FFI on PC): GDI copies the game window's picture off the screen, and GDI+ writes the file.
--
-- A shot waits a few frames first, with this library's window, its toasts and (on a loader with
-- obsidian.ui.solo) every mod's drawing held back, so the picture has only the game in it. The engine
-- shows a frame a little after Lua draws it, so the copy is taken after the frames it shows are clear.
--
-- Every C name goes through a name of this library's, `obsapi_<name> __asm__("<name>")`: LuaJIT keeps
-- one namespace for every script in the process, and two mods declaring the same name fail.
local menu = obsidian.module("lib/menu")

local bit = rawget(_G, "bit") or require("bit")

local M = { pending = nil, hidden = false, failed = nil }

-- Frames the screen goes without anything of a mod's on it before the copy.
M.WAIT_FRAMES = 3
M.FOLDER_NAME = "Helldivers"

local CSIDL_MYPICTURES = 0x27
local SRCCOPY, CAPTUREBLT = 0x00CC0020, 0x40000000
local PW_CLIENTONLY, PW_RENDERFULLCONTENT = 1, 2
local CP_UTF8 = 65001
local PIXEL_24BPP_RGB = 0x00021808

local C = nil -- { ffi, user32, gdi32, gdiplus, shell32, kernel32 }, once loaded
local token = nil -- GDI+ stays started once it has started

local DECLARATIONS = [[
typedef struct { long left, top, right, bottom; } obsapi_RECT;
typedef struct { long x, y; } obsapi_POINT;
typedef struct { unsigned long biSize; long biWidth; long biHeight; unsigned short biPlanes; unsigned short biBitCount;
	unsigned long biCompression; unsigned long biSizeImage; long biXPelsPerMeter; long biYPelsPerMeter;
	unsigned long biClrUsed; unsigned long biClrImportant; } obsapi_BITMAPINFOHEADER;
typedef struct { obsapi_BITMAPINFOHEADER bmiHeader; unsigned long bmiColors[3]; } obsapi_BITMAPINFO;
typedef struct { unsigned long Data1; unsigned short Data2; unsigned short Data3; unsigned char Data4[8]; } obsapi_GUID;
typedef struct { unsigned int GdiplusVersion; void *DebugEventCallback; int SuppressBackgroundThread; int SuppressExternalCodecs; } obsapi_GdiplusStartupInput;
typedef struct { obsapi_GUID Guid; unsigned long NumberOfValues; unsigned long Type; void *Value; } obsapi_EncoderParameter;
typedef struct { unsigned int Count; obsapi_EncoderParameter Parameter[1]; } obsapi_EncoderParameters;
typedef int (__stdcall *obsapi_WNDENUMPROC)(void *hwnd, intptr_t lparam);

void *obsapi_GetForegroundWindow(void) __asm__("GetForegroundWindow");
unsigned long obsapi_GetWindowThreadProcessId(void *hwnd, unsigned long *pid) __asm__("GetWindowThreadProcessId");
int obsapi_EnumWindows(obsapi_WNDENUMPROC fn, intptr_t lparam) __asm__("EnumWindows");
int obsapi_IsWindowVisible(void *hwnd) __asm__("IsWindowVisible");
int obsapi_IsIconic(void *hwnd) __asm__("IsIconic");
int obsapi_GetClientRect(void *hwnd, obsapi_RECT *rect) __asm__("GetClientRect");
int obsapi_ClientToScreen(void *hwnd, obsapi_POINT *point) __asm__("ClientToScreen");
void *obsapi_GetDC(void *hwnd) __asm__("GetDC");
int obsapi_ReleaseDC(void *hwnd, void *dc) __asm__("ReleaseDC");
int obsapi_PrintWindow(void *hwnd, void *dc, unsigned int flags) __asm__("PrintWindow");

void *obsapi_CreateCompatibleDC(void *dc) __asm__("CreateCompatibleDC");
int obsapi_DeleteDC(void *dc) __asm__("DeleteDC");
void *obsapi_CreateDIBSection(void *dc, const obsapi_BITMAPINFO *info, unsigned int usage, void **bits, void *section, unsigned long offset) __asm__("CreateDIBSection");
void *obsapi_SelectObject(void *dc, void *object) __asm__("SelectObject");
int obsapi_DeleteObject(void *object) __asm__("DeleteObject");
int obsapi_BitBlt(void *dc, int x, int y, int w, int h, void *src, int sx, int sy, unsigned long rop) __asm__("BitBlt");

unsigned long obsapi_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
int obsapi_MultiByteToWideChar(unsigned int page, unsigned long flags, const char *s, int n, wchar_t *out, int size) __asm__("MultiByteToWideChar");
int obsapi_WideCharToMultiByte(unsigned int page, unsigned long flags, const wchar_t *s, int n, char *out, int size, const char *def, int *used) __asm__("WideCharToMultiByte");

long obsapi_SHGetFolderPathW(void *hwnd, int folder, void *token, unsigned long flags, wchar_t *path) __asm__("SHGetFolderPathW");
int obsapi_SHCreateDirectoryExW(void *hwnd, const wchar_t *path, void *attributes) __asm__("SHCreateDirectoryExW");
void *obsapi_ShellExecuteW(void *hwnd, const wchar_t *verb, const wchar_t *file, const wchar_t *params, const wchar_t *dir, int show) __asm__("ShellExecuteW");

int obsapi_GdiplusStartup(uintptr_t *token, const obsapi_GdiplusStartupInput *input, void *output) __asm__("GdiplusStartup");
int obsapi_GdipCreateBitmapFromHBITMAP(void *bitmap, void *palette, void **image) __asm__("GdipCreateBitmapFromHBITMAP");
int obsapi_GdipCloneBitmapAreaI(int x, int y, int w, int h, int format, void *source, void **image) __asm__("GdipCloneBitmapAreaI");
int obsapi_GdipSaveImageToFile(void *image, const wchar_t *path, const obsapi_GUID *encoder, const obsapi_EncoderParameters *params) __asm__("GdipSaveImageToFile");
int obsapi_GdipDisposeImage(void *image) __asm__("GdipDisposeImage");
]]

-- The FFI, from the game's own require, or nil and why not.
local function find_ffi()
	if rawget(_G, "HAS_FFI") == false then return nil end
	local ok, ffi = pcall(require, "ffi")
	if ok and type(ffi) == "table" then return ffi end
	local loaded = type(package) == "table" and package.loaded
	if type(loaded) == "table" and type(loaded.ffi) == "table" then return loaded.ffi end
	return nil
end

local function load()
	if C then return C end
	if M.failed then return nil, M.failed end
	local ffi = find_ffi()
	if not ffi then
		M.failed = "no_ffi"
		return nil, M.failed
	end
	if ffi.os ~= "Windows" then
		M.failed = "not_windows"
		return nil, M.failed
	end
	local ok, err = pcall(ffi.cdef, DECLARATIONS)
	if not ok then
		obsidian.log("capture: " .. tostring(err))
		M.failed = "no_ffi"
		return nil, M.failed
	end
	local libs = { ffi = ffi }
	for _, name in ipairs({ "user32", "gdi32", "gdiplus", "shell32", "kernel32" }) do
		local ok2, lib = pcall(ffi.load, name)
		if not ok2 then
			obsidian.log("capture: no " .. name .. ": " .. tostring(lib))
			M.failed = "no_windows_library"
			return nil, M.failed
		end
		libs[name] = lib
	end
	C = libs
	return C
end

-- Whether shots can be taken here: true, or false and why not ("no_ffi", "not_windows", ...).
function M.available()
	local c, why = load()
	return c ~= nil, why
end

local function wide(s)
	local ffi, k = C.ffi, C.kernel32
	local n = k.obsapi_MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
	local out = ffi.new("wchar_t[?]", math.max(n, 1))
	k.obsapi_MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n)
	return out
end

local function narrow(w)
	local ffi, k = C.ffi, C.kernel32
	local n = k.obsapi_WideCharToMultiByte(CP_UTF8, 0, w, -1, nil, 0, nil, nil)
	if n <= 0 then return "" end
	local out = ffi.new("char[?]", n)
	k.obsapi_WideCharToMultiByte(CP_UTF8, 0, w, -1, out, n, nil, nil)
	return ffi.string(out)
end

local function guid(ffi, text)
	local a, b, c, d, e = text:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
	local g = ffi.new("obsapi_GUID")
	g.Data1, g.Data2, g.Data3 = tonumber(a, 16), tonumber(b, 16), tonumber(c, 16)
	local tail = d .. e
	for i = 0, 7 do g.Data4[i] = tonumber(tail:sub(i * 2 + 1, i * 2 + 2), 16) end
	return g
end

local ENCODERS = { png = "557CF406-1A04-11D3-9A73-0000F81EF32E", jpg = "557CF401-1A04-11D3-9A73-0000F81EF32E" }
local QUALITY = "1D5BE4B5-FA4A-452D-9CDD-5DB35105E7EB"

-- The Pictures folder of this Windows user (wherever it was moved), with a folder of `name` in it.
-- Answers the path, made if missing, or nil and why not.
function M.folder(name)
	local c, why = load()
	if not c then return nil, why end
	local buffer = c.ffi.new("wchar_t[?]", 520)
	if c.shell32.obsapi_SHGetFolderPathW(nil, CSIDL_MYPICTURES, nil, 0, buffer) ~= 0 then return nil, "no_pictures_folder" end
	local base = narrow(buffer)
	if base == "" then return nil, "no_pictures_folder" end
	local sub = type(name) == "string" and name:gsub("[\\/:*?\"<>|]", "") or M.FOLDER_NAME
	if sub == "" then sub = M.FOLDER_NAME end
	local path = base .. "\\" .. sub
	local made = c.shell32.obsapi_SHCreateDirectoryExW(nil, wide(path), nil)
	-- 0: made; 80 and 183: there already.
	if made ~= 0 and made ~= 80 and made ~= 183 then return nil, "no_folder" end
	return path
end

-- Opens a folder in Windows' file explorer.
function M.open_folder(path)
	local c, why = load()
	if not c then return false, why end
	if type(path) ~= "string" or path == "" then return false, "bad_type" end
	c.shell32.obsapi_ShellExecuteW(nil, wide("open"), wide(path), nil, nil, 1)
	return true
end

-- The game's window: the one in front when it belongs to this process, else the largest visible one
-- that does.
function M.find_window()
	local ffi, u = C.ffi, C.user32
	local me = C.kernel32.obsapi_GetCurrentProcessId()
	local pid = ffi.new("unsigned long[1]")
	local front = u.obsapi_GetForegroundWindow()
	if front ~= nil then
		u.obsapi_GetWindowThreadProcessId(front, pid)
		if pid[0] == me then return front end
	end
	local best, best_area = nil, 0
	local rect = ffi.new("obsapi_RECT")
	local callback = ffi.cast("obsapi_WNDENUMPROC", function(hwnd)
		local id = ffi.new("unsigned long[1]")
		u.obsapi_GetWindowThreadProcessId(hwnd, id)
		if id[0] == me and u.obsapi_IsWindowVisible(hwnd) ~= 0 and u.obsapi_GetClientRect(hwnd, rect) ~= 0 then
			local area = (rect.right - rect.left) * (rect.bottom - rect.top)
			if area > best_area then best, best_area = hwnd, area end
		end
		return 1
	end)
	pcall(u.obsapi_EnumWindows, callback, 0)
	callback:free()
	return best
end

-- Whether a picture came back black, as a window drawn by the graphics card can to a copy off the
-- screen: a sample of 64 pixels, all zero.
local function all_black(bits, w, h)
	local px = C.ffi.cast("uint32_t*", bits)
	for i = 0, 7 do
		for j = 0, 7 do
			local x, y = math.floor((i + 0.5) * w / 8), math.floor((j + 0.5) * h / 8)
			if bit.band(px[y * w + x], 0x00FFFFFF) ~= 0 then return false end
		end
	end
	return true
end

-- The part of a w by h picture to keep: crop = { x, y, w, h } in shares of the picture from its top left,
-- or an aspect ratio (a width over height, such as 16 / 9) to cut from the middle.
local function area(w, h, opts)
	local crop = opts.crop
	if type(crop) == "table" then
		local x, y = math.floor((crop.x or crop[1] or 0) * w + 0.5), math.floor((crop.y or crop[2] or 0) * h + 0.5)
		local cw, ch = math.floor((crop.w or crop[3] or 1) * w + 0.5), math.floor((crop.h or crop[4] or 1) * h + 0.5)
		x, y = math.max(0, math.min(x, w - 1)), math.max(0, math.min(y, h - 1))
		return x, y, math.max(1, math.min(cw, w - x)), math.max(1, math.min(ch, h - y))
	end
	local ratio = tonumber(opts.aspect)
	if ratio and ratio > 0 then
		if w / h > ratio then
			local cw = math.floor(h * ratio + 0.5)
			return math.floor((w - cw) / 2), 0, cw, h
		end
		local ch = math.floor(w / ratio + 0.5)
		return 0, math.floor((h - ch) / 2), w, ch
	end
	return 0, 0, w, h
end
M.area = area

local function start_gdiplus()
	if token then return true end
	local ffi = C.ffi
	local t = ffi.new("uintptr_t[1]")
	local input = ffi.new("obsapi_GdiplusStartupInput")
	input.GdiplusVersion = 1
	if C.gdiplus.obsapi_GdiplusStartup(t, input, nil) ~= 0 then return false end
	token = t[0]
	return true
end

local function unused_name(folder, stem, ext)
	local path = folder .. "\\" .. stem .. "." .. ext
	local n = 2
	while true do
		local f = io.open(path, "rb")
		if not f then return path end
		f:close()
		path = string.format("%s\\%s (%d).%s", folder, stem, n, ext)
		n = n + 1
	end
end

-- The copy and the file, right now. Answers the path, or nil and why not.
function M.save_now(opts)
	opts = opts or {}
	local c, why = load()
	if not c then return nil, why end
	local ffi, u, g = c.ffi, c.user32, c.gdi32
	local ext = opts.format == "jpg" and "jpg" or "png"
	local folder = opts.folder
	if not folder then
		local err
		folder, err = M.folder(opts.folder_name)
		if not folder then return nil, err end
	end
	local hwnd = M.find_window()
	if hwnd == nil then return nil, "no_window" end
	if u.obsapi_IsIconic(hwnd) ~= 0 then return nil, "minimized" end
	local rect = ffi.new("obsapi_RECT")
	if u.obsapi_GetClientRect(hwnd, rect) == 0 then return nil, "no_window" end
	local w, h = rect.right - rect.left, rect.bottom - rect.top
	if w <= 0 or h <= 0 then return nil, "no_window" end
	local corner = ffi.new("obsapi_POINT")
	u.obsapi_ClientToScreen(hwnd, corner)

	local screen = u.obsapi_GetDC(nil)
	if screen == nil then return nil, "no_screen" end
	local memory = g.obsapi_CreateCompatibleDC(screen)
	local info = ffi.new("obsapi_BITMAPINFO")
	info.bmiHeader.biSize = ffi.sizeof("obsapi_BITMAPINFOHEADER")
	info.bmiHeader.biWidth, info.bmiHeader.biHeight = w, -h
	info.bmiHeader.biPlanes, info.bmiHeader.biBitCount = 1, 32
	local bits = ffi.new("void*[1]")
	local bitmap = g.obsapi_CreateDIBSection(screen, info, 0, bits, nil, 0)
	local result, reason = nil, nil
	if bitmap == nil or memory == nil then
		reason = "no_memory"
	else
		local old = g.obsapi_SelectObject(memory, bitmap)
		g.obsapi_BitBlt(memory, 0, 0, w, h, screen, corner.x, corner.y, bit.bor(SRCCOPY, CAPTUREBLT))
		-- Exclusive fullscreen can hand back black off the screen; the window itself can then draw it.
		if all_black(bits[0], w, h) then
			u.obsapi_PrintWindow(hwnd, memory, bit.bor(PW_CLIENTONLY, PW_RENDERFULLCONTENT))
		end
		g.obsapi_SelectObject(memory, old)
		if all_black(bits[0], w, h) then
			reason = "black"
		elseif not start_gdiplus() then
			reason = "no_gdiplus"
		else
			local whole = ffi.new("void*[1]")
			if c.gdiplus.obsapi_GdipCreateBitmapFromHBITMAP(bitmap, nil, whole) ~= 0 then
				reason = "no_memory"
			else
				local x, y, cw, ch = area(w, h, opts)
				local part = ffi.new("void*[1]")
				local image = whole[0]
				if (x ~= 0 or y ~= 0 or cw ~= w or ch ~= h) and c.gdiplus.obsapi_GdipCloneBitmapAreaI(x, y, cw, ch, PIXEL_24BPP_RGB, whole[0], part) == 0 then
					image = part[0]
				end
				local stem = os.date(opts.name or "Helldivers %Y-%m-%d %H-%M-%S")
				stem = tostring(stem):gsub("[\\/:*?\"<>|]", "")
				local path = unused_name(folder, stem, ext)
				local params = nil
				if ext == "jpg" then
					params = ffi.new("obsapi_EncoderParameters")
					local quality = ffi.new("unsigned long[1]", math.max(1, math.min(100, math.floor(tonumber(opts.quality) or 95))))
					params.Count = 1
					params.Parameter[0].Guid = guid(ffi, QUALITY)
					params.Parameter[0].NumberOfValues = 1
					params.Parameter[0].Type = 4
					params.Parameter[0].Value = quality
					M.keep = quality
				end
				local status = c.gdiplus.obsapi_GdipSaveImageToFile(image, wide(path), guid(ffi, ENCODERS[ext]), params)
				if image ~= whole[0] then c.gdiplus.obsapi_GdipDisposeImage(image) end
				c.gdiplus.obsapi_GdipDisposeImage(whole[0])
				if status == 0 then result = path else reason = "not_saved" end
			end
		end
	end
	if bitmap ~= nil then g.obsapi_DeleteObject(bitmap) end
	if memory ~= nil then g.obsapi_DeleteDC(memory) end
	u.obsapi_ReleaseDC(nil, screen)
	return result, reason
end

-- Takes a shot after the screen clears of mods: M.WAIT_FRAMES frames with nothing of this library's or
-- any mod's drawn. done(path) gets the file's path, or done(nil, reason). opts: folder (a full path) or
-- folder_name (a folder in Pictures, "Helldivers" by default), name (an os.date pattern), format ("png"
-- or "jpg"), quality (1 to 100, JPEG), crop ({ x, y, w, h } in shares of the picture) or aspect (a width
-- over height, cut from the middle), keep (true: the calling mod's own drawing stays in the picture, a
-- tint or a caption, say; its guides are its to hide while busy()). Answers true, or false and why not.
function M.shot(opts, done)
	if M.pending then return false, "busy" end
	local ok, why = M.available()
	if not ok then return false, why end
	opts = type(opts) == "table" and opts or {}
	M.pending = { opts = opts, done = done, frames = M.WAIT_FRAMES, run = menu.runner() }
	M.hold_screen(true, opts.keep == true and { obsidian.caller() } or {})
	return true
end

-- Whether a shot is waiting, while the screen has to stay clear: a mod drawing its own guides checks it.
function M.busy()
	return M.pending ~= nil
end

-- Holds every mod's drawing back while a shot waits, where the loader can (obsidian.ui.solo), and
-- gives back whatever a mod had asked of it before.
local before = nil

function M.hold_screen(on, keep)
	M.hidden = on
	menu.held_back = on
	local ui = type(obsidian.ui) == "table" and obsidian.ui
	if not (ui and type(ui.solo) == "function") then return end
	if on then
		before = type(ui.soloed) == "function" and ui.soloed() or nil
		pcall(ui.solo, keep or {})
	else
		pcall(ui.solo, before)
		before = nil
	end
end

-- From the frame callback.
function M.tick()
	local p = M.pending
	if not p then return end
	p.frames = p.frames - 1
	if p.frames > 0 then return end
	M.pending = nil
	local ok, path, reason = pcall(M.save_now, p.opts)
	M.hold_screen(false)
	if not ok then
		obsidian.log("capture: " .. tostring(path))
		path, reason = nil, "failed"
	end
	if type(p.done) == "function" then
		local ok2, err = p.run(p.done, path, reason)
		if not ok2 and err ~= "off" then obsidian.log("capture: " .. tostring(err)) end
	end
end

-- For the tests: forget what was loaded.
function M.reset()
	C, M.failed, M.pending, M.hidden = nil, nil, nil, false
end

return M
