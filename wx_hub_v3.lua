--[[================================================================
    🌊 wx 🌊  —  Server Hop hub (v3)
    Đọc danh sách server CÔNG KHAI của Roblox rồi teleport bằng
    TeleportService. Không gửi dữ liệu người chơi đi đâu khác.

    v3 gộp 15 chức năng: lọc nâng cao, yêu thích, bỏ qua, hẹn giờ,
    tốc độ quét, bảng tiến trình, nhật ký lỗi, nhập/xuất JSON, khôi
    phục mặc định, tình trạng mạng, quản lý cache, UI gọn cho điện
    thoại, thao tác nhanh, chống teleport chồng, self-test.

    Trung thực: ping/fps chỉ dùng khi API trả về. JobId server chỉ
    tồn tại khi server còn người nên "yêu thích" có thể hết hạn.
    Cài đặt chỉ lưu lâu dài nếu executor có writefile/readfile.
================================================================]]

local GENV = _G
pcall(function()
    if type(getgenv) == "function" then GENV = getgenv() end
end)
if GENV.__WX_HUB_RUNNING then return end
GENV.__WX_HUB_RUNNING = true

local function MAIN()
    local Players            = game:GetService("Players")
    local TeleportService    = game:GetService("TeleportService")
    local HttpService        = game:GetService("HttpService")
    local UserInputService   = game:GetService("UserInputService")
    local MarketplaceService = game:GetService("MarketplaceService")

    local LocalPlayer = Players.LocalPlayer
    while not LocalPlayer do
        task.wait()
        LocalPlayer = Players.LocalPlayer
    end
    local PlaceId = game.PlaceId

    -- ============ Tiện ích ============
    local function now() return DateTime.now().UnixTimestampMillis / 1000 end
    local function nowMs() return DateTime.now().UnixTimestampMillis end
    local function nowSec() return math.floor(now()) end
    local function deepcopy(t)
        if type(t) ~= "table" then return t end
        local r = {}
        for k, v in pairs(t) do r[k] = deepcopy(v) end
        return r
    end
    local function fmtTime(sec)
        sec = math.floor(sec + 0.5)
        if sec < 60 then return sec .. " giây" end
        local m, s = math.floor(sec / 60), sec % 60
        if s == 0 then return m .. " phút" end
        return m .. " phút " .. s .. " giây"
    end

    -- ============ Hằng số ============
    local CONFIG = {
        HOP_COOLDOWN = 15, AUTO_CHECK_INTERVAL = 60, TELEPORT_TIMEOUT = 20,
        MAX_HOP_RETRY = 4, RETRY_MAX = 2, RETRY_BASE = 2,
        MIN_TELEPORT_GAP = 5, RECENT_TARGET_TTL = 30,
        LOG_MAX = 30, NET_HIST = 10, MAX_FAVORITES = 10, MAX_IGNORE = 100,
        IGNORE_AUTO_TTL = 300, IGNORE_ATTEMPT_TTL = 1800, IGNORE_MANUAL_TTL = 3600,
        SCHED_TICK = 20, MAX_IMPORT_BYTES = 20000,
    }
    local SCAN_LEVELS = { 1, 3, 5, 8, 12, 20, 30, 50, 75, 100 }
    local SPEED = {
        slow     = { label = "Chậm",     interval = 5, pageDelay = 2.5, perMin = 8 },
        balanced = { label = "Cân bằng", interval = 3, pageDelay = 1.5, perMin = 12 },
        fast     = { label = "Nhanh",    interval = 2, pageDelay = 1.0, perMin = 20 },
    }
    local SPEED_ORDER = { "slow", "balanced", "fast" }
    local TTL_CHOICES = { 15, 30, 60, 120, 300 }
    local SORT_ORDER = { "fewest", "ping", "fps", "random" }
    local SORT_LABEL = { fewest = "Ít người nhất", ping = "Ping thấp nhất", fps = "FPS cao nhất", random = "Ngẫu nhiên" }
    local MISSING_LABEL = { allow = "Cho qua", reject = "Loại bỏ" }
    local API_HOSTS = {
        roblox  = { name = "Roblox",  base = "https://games.roblox.com" },
        roproxy = { name = "RoProxy", base = "https://games.roproxy.com" },
    }
    local API_CHOICES = {
        { key = "roblox",  label = "Roblox",
          desc = "API chính thức của Roblox (games.roblox.com). An toàn nhất, mặc định." },
        { key = "roproxy", label = "RoProxy",
          desc = "Bản sao RoProxy — dịch vụ BÊN THỨ BA, sẽ thấy IP + PlaceId của bạn." },
        { key = "auto",    label = "Tự động",
          desc = "Roblox trước; chỉ chuyển sang RoProxy khi lỗi mạng/5xx/403. Gặp 429 thì NGHỈ, không đổi API để né giới hạn." },
    }

    local DEFAULTS = {
        threshold = 1, api = "roblox", scanLevel = 4, speed = "balanced", cacheTTL = 30, compact = false,
        filter = { minPlayers = 1, minFree = 1, maxPing = 0, minFps = 0, missing = "allow", sort = "fewest" },
        schedule = { enabled = false, start = "", stop = "", limitMin = 0 },
        autoStartedAt = 0,
    }
    local settings = deepcopy(DEFAULTS)
    local store = { favorites = {}, ignore = {} }
    local ui = { pages = {}, syncers = {}, minimized = false }

    -- ============ Trạng thái chung ============
    local running = true
    local autoEnabled = false
    local autoGen, autoCycleCount, autoFailureCount = 0, 0, 0
    local lastHopAttempt, lastTeleportAt = 0, 0
    local lastTargetId, lastHopFromAuto, lastTeleportKind = nil, false, "hop"
    local hopRetryCount, teleportGen, teleportStarted = 0, 0, false
    local recentTargets, attempts = {}, {}
    local resumeAuto = false
    local lastScanStats = nil

    local THEME = {
        BG = Color3.fromRGB(8, 11, 18), CARD = Color3.fromRGB(15, 22, 34),
        CARD_STROKE = Color3.fromRGB(0, 105, 190), HEADER_1 = Color3.fromRGB(0, 55, 120),
        HEADER_2 = Color3.fromRGB(0, 150, 230), HEADER_SUB = Color3.fromRGB(170, 215, 255),
        ACCENT = Color3.fromRGB(0, 180, 255), TEXT_MAIN = Color3.fromRGB(225, 240, 255),
        TEXT_SUB = Color3.fromRGB(125, 165, 205), WHITE = Color3.fromRGB(255, 255, 255),
        OK = Color3.fromRGB(60, 220, 150), WAIT = Color3.fromRGB(255, 190, 60),
        ERR = Color3.fromRGB(255, 95, 115), BTN_HOP = Color3.fromRGB(0, 125, 220),
        BTN_OFF = Color3.fromRGB(26, 42, 66), BTN_ON = Color3.fromRGB(0, 160, 245),
        BTN_SMALL = Color3.fromRGB(20, 85, 150), BTN_CLOSE = Color3.fromRGB(190, 40, 70),
        TOGGLE_BG = Color3.fromRGB(10, 18, 30),
    }

    local function setStatus(text, color)
        if ui.status then
            ui.status.Text = text
            ui.status.TextColor3 = color or THEME.TEXT_SUB
        end
    end

    -- ============ Logic thuần (dễ kiểm thử) ============
    local ENUMS = {
        api = { roblox = true, roproxy = true, auto = true },
        speed = { slow = true, balanced = true, fast = true },
        missing = { allow = true, reject = true },
        sort = { fewest = true, ping = true, fps = true, random = true },
        reason = { manual = true, auto = true, attempts = true },
    }

    local function parseHHMM(s)
        if type(s) ~= "string" then return nil end
        local h, m = s:match("^(%d%d?):(%d%d)$")
        h, m = tonumber(h), tonumber(m)
        if not h or h > 23 or m > 59 then return nil end
        return h * 60 + m
    end
    local function isInt(v, lo, hi)
        return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
    end
    local function validId(id)
        return type(id) == "string" and #id >= 8 and #id <= 64 and id:match("^[%w%-]+$") ~= nil
    end

    -- Kiểm tra cấu hình JSON: trả về ok, đã-làm-sạch, danh sách lỗi, danh sách cảnh báo
    local function validateConfig(t)
        local errs, warns, out = {}, {}, {}
        if type(t) ~= "table" then return false, nil, { "Gốc JSON phải là object" }, warns end
        local function bad(m) errs[#errs + 1] = m end
        local function int(src, key, lo, hi, dst, label)
            local v = src[key]
            if v == nil then return end
            if isInt(v, lo, hi) then dst[key] = v else bad(("%s: cần số nguyên %d–%d"):format(label or key, lo, hi)) end
        end
        local function enum(src, key, set, dst, label)
            local v = src[key]
            if v == nil then return end
            if type(v) == "string" and set[v] then dst[key] = v else bad((label or key) .. ": giá trị không hợp lệ") end
        end
        local function bool(src, key, dst, label)
            local v = src[key]
            if v == nil then return end
            if type(v) == "boolean" then dst[key] = v else bad((label or key) .. ": cần true/false") end
        end
        local known = { version = true, threshold = true, api = true, scanLevel = true, speed = true,
            cacheTTL = true, compact = true, filter = true, schedule = true, favorites = true,
            ignore = true, auto = true, autoStartedAt = true }
        for k in pairs(t) do
            if not known[k] and #warns < 5 then warns[#warns + 1] = "bỏ qua trường lạ: " .. tostring(k) end
        end
        if t.version ~= nil and t.version ~= 1 then bad("version không hỗ trợ: " .. tostring(t.version)) end
        int(t, "threshold", 1, 200, out)
        enum(t, "api", ENUMS.api, out)
        int(t, "scanLevel", 1, #SCAN_LEVELS, out)
        enum(t, "speed", ENUMS.speed, out)
        int(t, "cacheTTL", 10, 600, out)
        bool(t, "compact", out)
        bool(t, "auto", out)
        if t.autoStartedAt ~= nil then
            if type(t.autoStartedAt) == "number" and t.autoStartedAt >= 0 then out.autoStartedAt = t.autoStartedAt
            else bad("autoStartedAt: cần số ≥ 0") end
        end
        if t.filter ~= nil then
            if type(t.filter) ~= "table" then bad("filter: cần object") else
                out.filter = {}
                int(t.filter, "minPlayers", 0, 200, out.filter, "filter.minPlayers")
                int(t.filter, "minFree", 1, 200, out.filter, "filter.minFree")
                int(t.filter, "maxPing", 0, 2000, out.filter, "filter.maxPing")
                int(t.filter, "minFps", 0, 240, out.filter, "filter.minFps")
                enum(t.filter, "missing", ENUMS.missing, out.filter, "filter.missing")
                enum(t.filter, "sort", ENUMS.sort, out.filter, "filter.sort")
            end
        end
        if t.schedule ~= nil then
            if type(t.schedule) ~= "table" then bad("schedule: cần object") else
                local sc, dst = t.schedule, {}
                out.schedule = dst
                bool(sc, "enabled", dst, "schedule.enabled")
                int(sc, "limitMin", 0, 1440, dst, "schedule.limitMin")
                for _, k in ipairs({ "start", "stop" }) do
                    local v = sc[k]
                    if v ~= nil then
                        if v == "" or parseHHMM(v) then dst[k] = v else bad("schedule." .. k .. ": cần HH:MM") end
                    end
                end
            end
        end
        if t.favorites ~= nil then
            if type(t.favorites) ~= "table" then bad("favorites: cần mảng") else
                out.favorites = {}
                if #t.favorites > CONFIG.MAX_FAVORITES then bad("favorites: tối đa " .. CONFIG.MAX_FAVORITES) end
                for i, e in ipairs(t.favorites) do
                    if type(e) ~= "table" or not validId(e.id) or not isInt(e.place or -1, 1, 1e15) then
                        bad(("favorites[%d]: id/place không hợp lệ"):format(i))
                    else
                        out.favorites[#out.favorites + 1] = {
                            id = e.id, place = e.place,
                            label = type(e.label) == "string" and e.label:sub(1, 40) or "",
                            players = isInt(e.players or 0, 0, 200) and (e.players or 0) or 0,
                            maxPlayers = isInt(e.maxPlayers or 0, 0, 200) and (e.maxPlayers or 0) or 0,
                            savedAt = type(e.savedAt) == "number" and e.savedAt or 0,
                            fails = isInt(e.fails or 0, 0, 10) and (e.fails or 0) or 0,
                        }
                    end
                end
            end
        end
        if t.ignore ~= nil then
            if type(t.ignore) ~= "table" then bad("ignore: cần mảng") else
                out.ignore = {}
                if #t.ignore > CONFIG.MAX_IGNORE then bad("ignore: tối đa " .. CONFIG.MAX_IGNORE) end
                for i, e in ipairs(t.ignore) do
                    if type(e) ~= "table" or not validId(e.id) or type(e.exp) ~= "number"
                        or not (type(e.reason) == "string" and ENUMS.reason[e.reason]) then
                        bad(("ignore[%d]: không hợp lệ"):format(i))
                    else
                        out.ignore[#out.ignore + 1] = { id = e.id, exp = e.exp, reason = e.reason,
                            count = isInt(e.count or 1, 1, 1000) and (e.count or 1) or 1 }
                    end
                end
            end
        end
        return #errs == 0, out, errs, warns
    end

    -- Bộ lọc nâng cao: chỉ dùng ping/fps khi API trả về số
    local function passesFilter(s, threshold, f, selfId, ignoreTbl, t)
        if type(s) ~= "table" or type(s.id) ~= "string" or s.id == "" then return false end
        if s.id == selfId then return false end
        local playing = tonumber(s.playing) or 0
        local maxP = tonumber(s.maxPlayers) or 0
        if maxP > 0 and (maxP - playing) < math.max(1, f.minFree) then return false end
        if playing < f.minPlayers or playing > threshold then return false end
        if f.maxPing > 0 then
            if type(s.ping) == "number" then
                if s.ping > f.maxPing then return false end
            elseif f.missing == "reject" then return false end
        end
        if f.minFps > 0 then
            if type(s.fps) == "number" then
                if s.fps < f.minFps then return false end
            elseif f.missing == "reject" then return false end
        end
        local e = ignoreTbl[s.id]
        if e and e.exp > t then return false end
        return true
    end

    local function sortCandidates(list, mode)
        local function num(v, d) return type(v) == "number" and v or d end
        if mode == "random" then
            for i = #list, 2, -1 do
                local j = math.random(1, i)
                list[i], list[j] = list[j], list[i]
            end
            return list
        end
        table.sort(list, function(a, b)
            if mode == "ping" then
                local pa, pb = num(a.ping, math.huge), num(b.ping, math.huge)
                if pa ~= pb then return pa < pb end
            elseif mode == "fps" then
                local fa, fb = num(a.fps, -1), num(b.fps, -1)
                if fa ~= fb then return fa > fb end
            end
            if a.playing ~= b.playing then return a.playing < b.playing end
            local pa, pb = num(a.ping, math.huge), num(b.ping, math.huge)
            if pa ~= pb then return pa < pb end
            return a.id < b.id
        end)
        return list
    end

    local function pickCandidate(candidates, ignoreTbl, recent, t)
        local pool = {}
        for _, c in ipairs(candidates) do
            local e = ignoreTbl[c.id]
            local r = recent[c.id]
            if not (e and e.exp > t) and not (r and (t - r) < CONFIG.RECENT_TARGET_TTL) then
                pool[#pool + 1] = c
            end
        end
        if #pool == 0 then return nil end
        return pool[math.random(1, math.min(3, #pool))]
    end

    -- Danh sách bỏ qua / yêu thích (hàm thuần trên bảng truyền vào)
    local function ignoreAdd(tbl, id, reason, ttl, t, count)
        local n = 0
        for _ in pairs(tbl) do n = n + 1 end
        if n >= CONFIG.MAX_IGNORE and not tbl[id] then
            local oldest, oid = math.huge, nil
            for k, e in pairs(tbl) do if e.exp < oldest then oldest, oid = e.exp, k end end
            if oid then tbl[oid] = nil end
        end
        tbl[id] = { exp = t + ttl, reason = reason, count = count or 1 }
    end
    local function ignorePrune(tbl, t)
        for id, e in pairs(tbl) do if e.exp <= t then tbl[id] = nil end end
    end
    local function favAdd(list, entry, max)
        for _, e in ipairs(list) do if e.id == entry.id then return false, "Đã có trong danh sách yêu thích" end end
        if #list >= max then return false, "Danh sách đầy (tối đa " .. max .. ")" end
        list[#list + 1] = entry
        return true
    end
    local function favRemove(list, id)
        for i, e in ipairs(list) do
            if e.id == id then table.remove(list, i) return true end
        end
        return false
    end

    -- Hẹn giờ: trả về hành động ("start"/"stop"/"limit"/nil) và khoá phút đã xử lý
    local function scheduleDecision(nowMin, nowS, sched, autoOn, startedAt, lastKey, dayKey)
        if not sched.enabled then return nil, lastKey end
        if autoOn and sched.limitMin > 0 and startedAt > 0 and (nowS - startedAt) >= sched.limitMin * 60 then
            return "limit", lastKey
        end
        local key = tostring(dayKey) .. ":" .. nowMin
        if key ~= lastKey then
            local startM, stopM = parseHHMM(sched.start), parseHHMM(sched.stop)
            if startM and not autoOn and nowMin == startM then return "start", key end
            if stopM and autoOn and nowMin == stopM then return "stop", key end
        end
        return nil, lastKey
    end

    -- Giới hạn tốc độ: thời gian cần chờ trước request kế tiếp
    local function computeWait(stamps, t, interval, perMin, penalty)
        local w = 0
        local last = stamps[#stamps]
        if last then w = math.max(w, last + interval * penalty - t) end
        local inWin = {}
        for _, s in ipairs(stamps) do if t - s < 60 then inWin[#inWin + 1] = s end end
        if #inWin >= perMin then w = math.max(w, inWin[#inWin - perMin + 1] + 60 - t) end
        return math.max(w, 0)
    end
    local function adjustPenalty(p, event)
        if event == "429" then return math.min(4, p * 2) end
        if event == "5xx" then return math.min(4, p * 1.5) end
        return math.max(1, p * 0.85)
    end

    local function filterSig(f)
        return table.concat({ f.minPlayers, f.minFree, f.maxPing, f.minFps, f.missing, f.sort }, ",")
    end
    local function cacheKey(threshold, level, api, f)
        return table.concat({ threshold, level, api, filterSig(f) }, "|")
    end
    local function cacheValid(entry, key, ttl, t)
        return entry ~= nil and entry.key == key and (t - entry.at) < ttl
    end

    -- Phân loại nguyên nhân lỗi (chỉ nêu nguyên nhân có thể xác định từ mã/tên lỗi)
    local HTTP_CAUSES = {
        [400] = "Yêu cầu không hợp lệ (PlaceId/tham số)",
        [401] = "API từ chối truy cập",
        [403] = "Bị chặn (403): proxy/executor có thể bị chặn",
        [404] = "Không có danh sách server công khai cho game này, hoặc API đã đổi",
        [429] = "Vượt giới hạn tần suất — cần giảm tốc / chờ",
    }
    local STR_CAUSES = {
        json = "Phản hồi không phải JSON hợp lệ (có thể bị trang chặn/proxy)",
        empty = "Phản hồi rỗng từ máy chủ",
        exception = "Executor không gửi được HTTP hoặc bị chặn",
        cooldown = "Đang nghỉ để tránh bị giới hạn",
    }
    local TP_CAUSES = {
        GameFull = "Server đã đầy", GameEnded = "Server đã đóng (ID hết hạn)",
        GameNotFound = "Server/place không còn tồn tại", Unauthorized = "Không có quyền vào server này",
        Flooded = "Teleport quá dày — cần chờ", IsTeleporting = "Đang có teleport khác",
        Failure = "Roblox báo lỗi chung — thử server khác",
    }
    local function classifyHttp(code)
        if type(code) == "string" then return STR_CAUSES[code] or "Không xác định" end
        code = tonumber(code)
        if code and HTTP_CAUSES[code] then return HTTP_CAUSES[code] end
        if code and code >= 500 then return "Lỗi phía máy chủ (thường tạm thời)" end
        return "Không xác định"
    end
    local function classifyTeleport(result)
        local name = tostring(result):match("(%w+)$")
        return TP_CAUSES[name or ""] or "Không xác định"
    end
    local function classify(src, code)
        if src == "http" then return classifyHttp(code) end
        if src == "teleport" then return classifyTeleport(code) end
        if src == "save" then return "Executor không cho ghi/đọc file hoặc file hỏng" end
        if src == "import" then return "Dữ liệu nhập không đúng định dạng" end
        if src == "ui" then return "Lỗi nội bộ khi xử lý thao tác" end
        return "Không xác định"
    end

    -- ============ Nhật ký lỗi ============
    local errlog = {}
    local function renderLog()
        if not ui.logText then return end
        if #errlog == 0 then ui.logText.Text = "Chưa có lỗi nào được ghi." return end
        local lines, shown = {}, 0
        for i = #errlog, 1, -1 do
            local e = errlog[i]
            lines[#lines + 1] = ("[%s] %s • %s\n→ %s\n%s"):format(os.date("%H:%M:%S", e.t), e.src,
                tostring(e.code), e.cause, e.msg:sub(1, 110))
            shown = shown + 1
            if shown >= 15 then break end
        end
        ui.logText.Text = table.concat(lines, "\n\n")
    end
    local function logError(src, code, msg)
        errlog[#errlog + 1] = { t = nowSec(), src = src, code = code, msg = tostring(msg or ""), cause = classify(src, code) }
        if #errlog > CONFIG.LOG_MAX then table.remove(errlog, 1) end
        renderLog()
    end

    -- ============ Lưu / tải cấu hình ============
    local SAVE_FILE = "wx_hub.json"
    local canSave = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

    local function ignoreToArray(tbl, t)
        local arr = {}
        for id, e in pairs(tbl) do
            if e.exp > t then arr[#arr + 1] = { id = id, exp = e.exp, reason = e.reason, count = e.count } end
        end
        table.sort(arr, function(a, b) return a.id < b.id end)
        return arr
    end
    local function snapshot(forFile)
        local s = {
            version = 1, threshold = settings.threshold, api = settings.api, scanLevel = settings.scanLevel,
            speed = settings.speed, cacheTTL = settings.cacheTTL, compact = settings.compact,
            filter = deepcopy(settings.filter), schedule = deepcopy(settings.schedule),
            favorites = deepcopy(store.favorites), ignore = ignoreToArray(store.ignore, nowSec()),
        }
        if forFile then s.auto = autoEnabled; s.autoStartedAt = settings.autoStartedAt end
        return s
    end
    local function applyConfig(out, includeAuto)
        for _, k in ipairs({ "threshold", "api", "scanLevel", "speed", "cacheTTL", "compact" }) do
            if out[k] ~= nil then settings[k] = out[k] end
        end
        if out.filter then for k, v in pairs(out.filter) do settings.filter[k] = v end end
        if out.schedule then for k, v in pairs(out.schedule) do settings.schedule[k] = v end end
        if out.favorites then store.favorites = out.favorites end
        if out.ignore then
            store.ignore = {}
            for _, e in ipairs(out.ignore) do store.ignore[e.id] = { exp = e.exp, reason = e.reason, count = e.count } end
        end
        if includeAuto then
            resumeAuto = (out.auto == true)
            settings.autoStartedAt = out.autoStartedAt or 0
        end
    end
    local function saveNow()
        if not canSave then return false end
        local ok, err = pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(snapshot(true))) end)
        if not ok then logError("save", "write", err) end
        return ok
    end
    local saveQueued = false
    local function saveSoon()
        if not canSave or saveQueued then return end
        saveQueued = true
        task.delay(1.5, function() saveQueued = false; saveNow() end)
    end
    local loadNote = nil
    local function loadSaved()
        if not canSave then return end
        local okE, exists = pcall(isfile, SAVE_FILE)
        if not (okE and exists) then return end
        local okR, raw = pcall(readfile, SAVE_FILE)
        if not okR or type(raw) ~= "string" then logError("save", "read", raw) return end
        local okJ, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if not okJ then logError("save", "json", data) loadNote = "File cấu hình hỏng — dùng mặc định" return end
        local ok, out, errs = validateConfig(data)
        if not ok then logError("save", "invalid", errs[1]) loadNote = "File cấu hình không hợp lệ — dùng mặc định" return end
        applyConfig(out, true)
    end
    loadSaved()
    ignorePrune(store.ignore, nowSec())

    -- ============ Safe Teleport Guard ============
    local guard = { owner = nil, token = 0, since = 0, cancel = false, onChange = nil }
    local function guardNotify() if guard.onChange then guard.onChange() end end
    local function guardAcquire(owner)
        if not running or (ui.gui and not ui.gui.Parent) then return nil, "UI đã đóng" end
        if guard.owner then return nil, "Đang bận (" .. guard.owner .. ")" end
        guard.token = guard.token + 1
        guard.owner, guard.since, guard.cancel = owner, now(), false
        guardNotify()
        return guard.token
    end
    local function guardSet(token, owner)
        if token == guard.token and guard.owner then guard.owner = owner guardNotify() end
    end
    local function guardRelease(token)
        if token ~= nil and token == guard.token and guard.owner then
            guard.owner, guard.cancel = nil, false
            guardNotify()
        end
    end

    -- ============ Mạng: giới hạn tốc độ + tình trạng ============
    local httpRequest = (syn and syn.request) or http_request or request or (http and http.request)
    local net = { stamps = {}, penalty = 1, cool = {}, total = 0, hist = {} }
    local lastGoodApi = "roblox"

    local function recordNet(ok, code, ms)
        net.hist[#net.hist + 1] = { ok = ok, code = code, ms = ms, t = now() }
        if #net.hist > CONFIG.NET_HIST then table.remove(net.hist, 1) end
        if ui.onNet then ui.onNet() end
    end
    local function netSummary()
        local h = net.hist
        if #h == 0 then return "⚪ Chưa có yêu cầu nào", "Trạng thái dựa trên kết quả request thật; chưa gọi API." end
        local okN, sum = 0, 0
        for _, r in ipairs(h) do
            if r.ok then okN = okN + 1 end
            sum = sum + r.ms
        end
        local avg = math.floor(sum / #h)
        local detail = ("%d/%d yêu cầu gần nhất OK • TB %dms • tổng %d • giảm tốc ×%.1f")
            :format(okN, #h, avg, net.total, net.penalty)
        local cdLeft
        for _, until_ in pairs(net.cool) do
            local left = until_ - now()
            if left > 0 and (not cdLeft or left > cdLeft) then cdLeft = left end
        end
        if cdLeft then return ("🟠 Bị giới hạn (429) — nghỉ còn %ds"):format(math.ceil(cdLeft)), detail end
        local last = h[#h]
        if not last.ok then return "🔴 Lỗi gần nhất: " .. classifyHttp(last.code), detail end
        if avg > 2500 then return ("🟡 Chậm (TB %dms)"):format(avg), detail end
        return ("🟢 Tốt (TB %dms)"):format(avg), detail
    end

    local function waitForSlot(apiKey)
        local t = now()
        local cd = net.cool[apiKey]
        if cd and cd > t then
            return false, ("Đang nghỉ do bị giới hạn — còn %ds"):format(math.ceil(cd - t)), "cooldown"
        end
        local p = SPEED[settings.speed]
        local w = computeWait(net.stamps, t, p.interval, p.perMin, net.penalty)
        local waited = 0
        while waited < w do
            if guard.cancel then return false, "Đã hủy", "cooldown" end
            local step = math.min(1, w - waited)
            task.wait(step)
            waited = waited + step
        end
        t = now()
        net.stamps[#net.stamps + 1] = t
        while #net.stamps > 0 and t - net.stamps[1] >= 60 do table.remove(net.stamps, 1) end
        net.total = net.total + 1
        return true
    end

    local function headerValue(headers, name)
        if type(headers) ~= "table" then return nil end
        for k, v in pairs(headers) do
            if type(k) == "string" and k:lower() == name then return v end
        end
        return nil
    end

    -- Trả về data | nil, lỗi, mã (số hoặc chuỗi)
    local function httpGetJson(url, apiKey)
        local attempt = 0
        while true do
            local okSlot, why, code0 = waitForSlot(apiKey)
            if not okSlot then return nil, why, code0 end
            local t0 = nowMs()
            local okReq, r = pcall(function()
                if httpRequest then
                    return httpRequest({ Url = url, Method = "GET", Headers = { Accept = "application/json" } })
                end
                return game:HttpGet(url)
            end)
            if not okReq then
                recordNet(false, "exception", nowMs() - t0)
                logError("http", "exception", r)
                return nil, "Executor không gửi được request HTTP", "exception"
            end
            local code, body, headers = 0, nil, nil
            if type(r) == "table" then
                code = tonumber(r.StatusCode) or tonumber(r.Status) or 0
                body, headers = r.Body, r.Headers
            elseif type(r) == "string" then
                code, body = 200, r
            end
            local ms = nowMs() - t0
            if code == 200 then
                if type(body) ~= "string" or body == "" then
                    recordNet(false, "empty", ms) logError("http", "empty", url)
                    return nil, "Phản hồi rỗng", "empty"
                end
                local okJ, data = pcall(HttpService.JSONDecode, HttpService, body)
                if okJ and type(data) == "table" then
                    recordNet(true, 200, ms)
                    net.penalty = adjustPenalty(net.penalty, "ok")
                    return data
                end
                recordNet(false, "json", ms) logError("http", "json", body:sub(1, 80))
                return nil, "Dữ liệu trả về không phải JSON hợp lệ", "json"
            elseif code == 429 then
                recordNet(false, 429, ms)
                net.penalty = adjustPenalty(net.penalty, "429")
                local ra = tonumber(headerValue(headers, "retry-after"))
                local waitS = math.min(ra or (CONFIG.RETRY_BASE * (attempt + 1) * net.penalty), 30)
                if attempt >= CONFIG.RETRY_MAX then
                    local cd = math.min(math.max(waitS, 30 * net.penalty), 120)
                    net.cool[apiKey] = now() + cd
                    logError("http", 429, url)
                    return nil, ("Bị giới hạn (429) — tạm nghỉ %ds"):format(math.ceil(cd)), 429
                end
                setStatus(("⚠ Bị giới hạn 429 — chờ %ds rồi thử lại…"):format(math.ceil(waitS)), THEME.WAIT)
                task.wait(waitS)
                if guard.cancel then return nil, "Đã hủy", "cooldown" end
                attempt = attempt + 1
            elseif code >= 500 then
                recordNet(false, code, ms)
                net.penalty = adjustPenalty(net.penalty, "5xx")
                if attempt >= CONFIG.RETRY_MAX then
                    logError("http", code, url)
                    return nil, "Lỗi máy chủ (HTTP " .. code .. ")", code
                end
                task.wait(CONFIG.RETRY_BASE * (attempt + 1))
                attempt = attempt + 1
            else
                recordNet(false, code, ms)
                logError("http", code, url)
                return nil, "Lỗi HTTP " .. tostring(code), code
            end
        end
    end

    local function fetchPage(cursor)
        local order
        if settings.api == "auto" then
            order = (lastGoodApi == "roproxy") and { "roproxy", "roblox" } or { "roblox", "roproxy" }
        else
            order = { settings.api }
        end
        local lastErr = "Không rõ lỗi"
        for i, key in ipairs(order) do
            local host = API_HOSTS[key]
            local url = ("%s/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100")
                :format(host.base, PlaceId)
            if cursor then url = url .. "&cursor=" .. HttpService:UrlEncode(cursor) end
            local data, err, code = httpGetJson(url, key)
            if data then lastGoodApi = key return data end
            lastErr = host.name .. ": " .. tostring(err)
            if code == 429 or code == "cooldown" then break end -- không đổi API để né giới hạn
            if i < #order then setStatus("API " .. host.name .. " lỗi — thử API khác…", THEME.WAIT) end
        end
        return nil, lastErr
    end

    -- ============ Bảng tiến trình + Cache + Quét ============
    local PHASE = { idle = "Chờ", scan = "Đang quét", done = "Xong", teleport = "Teleport", error = "Lỗi", cancel = "Đã hủy" }
    local live = { phase = "idle", pagesDone = 0, maxPages = 0, scanned = 0, found = 0 }
    local function renderLive()
        if not ui.liveFill then return end
        local frac = 0
        if live.maxPages > 0 then frac = live.pagesDone / live.maxPages end
        if live.phase == "done" or live.phase == "teleport" then frac = 1 end
        ui.liveFill.Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0)
        ui.liveStats.Text = ("%s • trang %d/%d • quét %d • phù hợp %d • yêu cầu %d")
            :format(PHASE[live.phase] or "", live.pagesDone, live.maxPages, live.scanned, live.found, net.total)
    end
    local function liveSet(info)
        for k, v in pairs(info) do live[k] = v end
        renderLive()
    end

    local cache = { entry = nil }
    local function invalidateCache() cache.entry = nil end

    local function scanServers(threshold, opts)
        opts = opts or {}
        local f = opts.filter or settings.filter
        local fetch = opts.fetch or fetchPage
        local sleep = opts.wait or task.wait
        local progress = opts.onProgress or liveSet
        local maxPages = opts.maxPages or SCAN_LEVELS[settings.scanLevel]
        local key = cacheKey(threshold, settings.scanLevel, settings.api, f)
        if not opts.noCache and not opts.force and cacheValid(cache.entry, key, settings.cacheTTL, now()) then
            local e = cache.entry
            progress({ phase = "done", pagesDone = e.pages, maxPages = e.pages, scanned = e.scanned, found = #e.candidates })
            return e.candidates, nil, e.scanned, nil, { pages = e.pages, fromCache = true }
        end
        local selfId = tostring(game.JobId)
        local pageDelay = SPEED[settings.speed].pageDelay
        local candidates, scanned, pages, cursor, stopInfo = {}, 0, 0, nil, nil
        local pingSeen, fpsSeen = 0, 0
        progress({ phase = "scan", pagesDone = 0, maxPages = maxPages, scanned = 0, found = 0 })
        local t = now()
        for page = 1, maxPages do
            if guard.cancel and not opts.ignoreCancel then stopInfo = "Đã hủy quét" break end
            pages = page
            local data, err = fetch(cursor)
            if not data then
                if page == 1 then progress({ phase = "error" }) return nil, err, 0 end
                stopInfo = "Quét dừng giữa chừng: " .. tostring(err)
                break
            end
            local list = type(data.data) == "table" and data.data or {}
            for _, s in ipairs(list) do
                scanned = scanned + 1
                if type(s) == "table" then
                    if type(s.ping) == "number" then pingSeen = pingSeen + 1 end
                    if type(s.fps) == "number" then fpsSeen = fpsSeen + 1 end
                    if passesFilter(s, threshold, f, selfId, store.ignore, t) then
                        candidates[#candidates + 1] = {
                            id = s.id, playing = tonumber(s.playing) or 0, maxPlayers = tonumber(s.maxPlayers) or 0,
                            ping = type(s.ping) == "number" and s.ping or nil,
                            fps = type(s.fps) == "number" and s.fps or nil,
                        }
                    end
                end
            end
            progress({ pagesDone = page, scanned = scanned, found = #candidates })
            if #candidates > 0 then break end
            cursor = data.nextPageCursor
            if type(cursor) ~= "string" or cursor == "" then break end
            if page < maxPages then sleep(pageDelay) end
        end
        sortCandidates(candidates, f.sort)
        local meta = { pages = pages, pingSeen = pingSeen, fpsSeen = fpsSeen }
        if not opts.noStats then lastScanStats = { scanned = scanned, pingSeen = pingSeen, fpsSeen = fpsSeen } end
        if not stopInfo and not opts.noCache then
            cache.entry = { key = key, candidates = candidates, scanned = scanned, pages = pages, at = now() }
        end
        progress({ phase = stopInfo == "Đã hủy quét" and "cancel" or "done" })
        return candidates, nil, scanned, stopInfo, meta
    end

    -- =================== GUI ===================
    local function make(class, props, parent)
        local inst = Instance.new(class)
        if props then for k, v in pairs(props) do inst[k] = v end end
        inst.Parent = parent
        return inst
    end
    local function corner(r, p) return make("UICorner", { CornerRadius = UDim.new(0, r) }, p) end
    local function stroke(c, th, p) return make("UIStroke", { Color = c, Thickness = th, Transparency = 0.15 }, p) end
    local function guarded(fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                logError("ui", "exception", err)
                setStatus("Lỗi nội bộ: " .. tostring(err):sub(1, 100), THEME.ERR)
            end
        end
    end
    local function onClick(btn, fn) btn.MouseButton1Click:Connect(guarded(fn)) end

    local gameName = "Không xác định"
    pcall(function() gameName = MarketplaceService:GetProductInfo(PlaceId).Name or gameName end)

    local function removeOldGui(parent)
        pcall(function()
            for _, name in ipairs({ "NuoiBungSVHub", "WXHub" }) do
                local old = parent:FindFirstChild(name)
                if old then old:Destroy() end
            end
        end)
    end
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "WXHub"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.DisplayOrder = 9999
    ScreenGui.IgnoreGuiInset = true
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ui.gui = ScreenGui

    local guiParented = false
    local function tryParent(parent)
        if not parent then return false end
        local ok = pcall(function() removeOldGui(parent) ScreenGui.Parent = parent end)
        return ok and ScreenGui.Parent == parent
    end
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then guiParented = tryParent(hui) end
    end
    if not guiParented and syn and type(syn.protect_gui) == "function" then
        pcall(syn.protect_gui, ScreenGui)
    end
    if not guiParented then
        local ok, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok and cg then guiParented = tryParent(cg) end
    end
    if not guiParented then
        local ok, pg = pcall(function() return LocalPlayer:WaitForChild("PlayerGui", 5) end)
        if ok and pg then guiParented = tryParent(pg) end
    end
    if not guiParented then
        ScreenGui:Destroy()
        error("Không thể đặt ScreenGui vào gethui, CoreGui hoặc PlayerGui.")
    end

    -- Kích thước theo màn hình (điện thoại ngang thường chỉ cao ~360px)
    local function viewport()
        local cam = workspace.CurrentCamera
        local vs = cam and cam.ViewportSize
        if vs and vs.X > 0 and vs.Y > 0 then return vs.X, vs.Y end
        return 800, 600
    end
    local function metrics()
        local vx, vy = viewport()
        return {
            W = math.clamp(vx - 24, 280, 400), H = math.clamp(vy - 24, 220, 500),
            compact = settings.compact or vy < 480 or vx < 420,
        }
    end

    local MainFrame = make("Frame", {
        Size = UDim2.new(0, 390, 0, 470), Position = UDim2.new(0, 10, 0, 10),
        BackgroundColor3 = THEME.BG, BorderSizePixel = 0, Active = true, ClipsDescendants = true,
    }, ScreenGui)
    corner(16, MainFrame)
    stroke(THEME.HEADER_2, 2, MainFrame)
    ui.main = MainFrame

    local Toggle = make("TextButton", {
        Name = "WXToggle", Size = UDim2.new(0, 50, 0, 50), Position = UDim2.new(0, 10, 0.5, -25),
        BackgroundColor3 = THEME.TOGGLE_BG, BorderSizePixel = 0, Text = "🌊", TextColor3 = THEME.WHITE,
        TextSize = 26, Font = Enum.Font.GothamBold, ZIndex = 100, Active = true,
    }, ScreenGui)
    corner(25, Toggle)
    stroke(THEME.ACCENT, 2, Toggle)
    onClick(Toggle, function() MainFrame.Visible = not MainFrame.Visible end)

    local Header = make("Frame", { Size = UDim2.new(1, 0, 0, 60), BackgroundColor3 = THEME.HEADER_1, BorderSizePixel = 0 }, MainFrame)
    corner(16, Header)
    local HeaderPatch = make("Frame", { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 1, -18),
        BackgroundColor3 = THEME.HEADER_1, BorderSizePixel = 0 }, Header)
    make("UIGradient", { Color = ColorSequence.new(THEME.HEADER_1, THEME.HEADER_2), Rotation = 0 }, Header)
    make("UIGradient", { Color = ColorSequence.new(THEME.HEADER_1, THEME.HEADER_2), Rotation = 0 }, HeaderPatch)
    ui.header = Header

    local function text(parent, props)
        props.BackgroundTransparency = 1
        props.Font = props.Font or Enum.Font.Gotham
        props.TextColor3 = props.TextColor3 or THEME.TEXT_SUB
        props.TextSize = props.TextSize or 12
        props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
        return make("TextLabel", props, parent)
    end
    ui.title = text(Header, { Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -90, 0, 26), Font = Enum.Font.GothamBlack,
        Text = "🌊 wx 🌊", TextColor3 = THEME.WHITE, TextSize = 19 })
    ui.sub = text(Header, { Position = UDim2.new(0, 12, 0, 34), Size = UDim2.new(1, -90, 0, 16),
        Text = gameName .. " • " .. tostring(PlaceId), TextColor3 = THEME.HEADER_SUB, TextSize = 11,
        TextTruncate = Enum.TextTruncate.AtEnd })
    local function hdrBtn(txt, bg)
        local b = make("TextButton", { Size = UDim2.new(0, 28, 0, 28), BackgroundColor3 = bg, BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, Text = txt, TextColor3 = THEME.WHITE, TextSize = 15 }, Header)
        corner(8, b)
        return b
    end
    local MinBtn, CloseBtn = hdrBtn("–", THEME.BTN_SMALL), hdrBtn("✕", THEME.BTN_CLOSE)

    ui.body = make("Frame", { Position = UDim2.new(0, 8, 0, 66), Size = UDim2.new(1, -16, 1, -72), BackgroundTransparency = 1 }, MainFrame)

    -- Thanh tab (cuộn ngang)
    local TABS = {
        { "hop", "🌊 Hop" }, { "filter", "🎛 Lọc" }, { "net", "📡 Mạng" }, { "srv", "⭐ Server" },
        { "sch", "⏰ Lịch" }, { "log", "📋 Log" }, { "tool", "🧰 Tools" },
    }
    local TabBar = make("ScrollingFrame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X, CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.X }, ui.body)
    make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, TabBar)
    local tabButtons, onShow = {}, {}
    local function showTab(key)
        for k, pg in pairs(ui.pages) do pg.frame.Visible = (k == key) end
        for k, b in pairs(tabButtons) do
            b.BackgroundColor3 = (k == key) and THEME.BTN_HOP or THEME.BTN_OFF
            b.TextColor3 = (k == key) and THEME.WHITE or THEME.TEXT_SUB
        end
        ui.tab = key
        if onShow[key] then onShow[key]() end
    end
    for i, tb in ipairs(TABS) do
        local b = make("TextButton", { Size = UDim2.new(0, 78, 1, -2), BorderSizePixel = 0, Font = Enum.Font.GothamBold,
            Text = tb[2], TextSize = 12, LayoutOrder = i }, TabBar)
        corner(9, b)
        tabButtons[tb[1]] = b
        onClick(b, function() showTab(tb[1]) end)
    end

    -- Helper trang / thẻ / hàng
    local orders = setmetatable({}, { __mode = "k" })
    local function nextOrder(p) orders[p] = (orders[p] or 0) + 1 return orders[p] end
    local function newPage(key)
        local sf = make("ScrollingFrame", { Position = UDim2.new(0, 0, 0, 36), Size = UDim2.new(1, 0, 1, -36),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
            ScrollingDirection = Enum.ScrollingDirection.Y, CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false }, ui.body)
        make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
        make("UIPadding", { PaddingRight = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8) }, sf)
        local pg = { frame = sf }
        ui.pages[key] = pg
        return pg
    end
    local function addCard(pg)
        local c = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = THEME.CARD,
            BorderSizePixel = 0, LayoutOrder = nextOrder(pg.frame) }, pg.frame)
        corner(12, c)
        stroke(THEME.CARD_STROKE, 1.5, c)
        make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, c)
        make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, c)
        return c
    end
    local function addRow(card, h)
        return make("Frame", { Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1, LayoutOrder = nextOrder(card) }, card)
    end
    local function addTitle(card, t)
        local r = addRow(card, 18)
        return text(r, { Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.GothamBold, Text = t, TextColor3 = THEME.TEXT_MAIN, TextSize = 13 })
    end
    local function addNote(card, t, h, props)
        local r = addRow(card, h or 30)
        local p = props or {}
        p.Size, p.Text, p.TextWrapped = UDim2.new(1, 0, 1, 0), t, true
        p.TextYAlignment = Enum.TextYAlignment.Top
        return text(r, p)
    end
    local function addButtons(card, specs, h)
        local r = addRow(card, h or 34)
        local n, out = #specs, {}
        for i, sp in ipairs(specs) do
            local b = make("TextButton", { Position = UDim2.new((i - 1) / n, 2, 0, 0), Size = UDim2.new(1 / n, -4, 1, 0),
                BackgroundColor3 = sp.bg or THEME.BTN_OFF, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
                Text = sp.text, TextColor3 = THEME.WHITE, TextSize = sp.ts or 12, TextWrapped = true }, r)
            corner(8, b)
            if sp.cb then onClick(b, sp.cb) end
            out[i] = b
        end
        return out, r
    end
    local function addField(card, label, value, onCommit)
        local r = addRow(card, 30)
        text(r, { Size = UDim2.new(0.6, -6, 1, 0), Text = label, TextColor3 = THEME.TEXT_MAIN, TextWrapped = true })
        local box = make("TextBox", { Position = UDim2.new(0.6, 0, 0, 0), Size = UDim2.new(0.4, 0, 1, 0), BackgroundColor3 = THEME.BG,
            BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = value, TextColor3 = THEME.TEXT_MAIN, TextSize = 13,
            ClearTextOnFocus = false }, r)
        corner(8, box)
        stroke(THEME.CARD_STROKE, 1, box)
        box.FocusLost:Connect(guarded(function() onCommit(box.Text, box) end))
        return box
    end
    local function addSelect(card, label, cb)
        local r = addRow(card, 32)
        text(r, { Size = UDim2.new(0.5, -6, 1, 0), Text = label, TextColor3 = THEME.TEXT_MAIN, TextWrapped = true })
        local b = make("TextButton", { Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0.5, 0, 1, 0), BackgroundColor3 = THEME.BTN_SMALL,
            BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = "", TextColor3 = THEME.WHITE, TextSize = 12 }, r)
        corner(8, b)
        onClick(b, cb)
        return b
    end
    local function intField(card, label, get, set, lo, hi)
        local box
        box = addField(card, label, tostring(get()), function(txt)
            local n = tonumber((txt:gsub("[^%d]", "")))
            if not n then
                box.Text = tostring(get())
                setStatus("Giá trị không hợp lệ — giữ nguyên " .. tostring(get()), THEME.WAIT)
                return
            end
            n = math.clamp(math.floor(n), lo, hi)
            set(n)
            box.Text = tostring(n)
            invalidateCache()
            saveSoon()
        end)
        ui.syncers[#ui.syncers + 1] = function() box.Text = tostring(get()) end
        return box
    end
    local function styleSel(b, on)
        b.BackgroundColor3 = on and THEME.BTN_ON or THEME.BTN_OFF
        b.TextColor3 = on and THEME.WHITE or THEME.TEXT_SUB
    end

    local function copyText(txt, fileName)
        if type(setclipboard) == "function" and pcall(setclipboard, txt) then return true, "clipboard" end
        if canSave and pcall(writefile, fileName, txt) then return true, "file " .. fileName end
        return false
    end

    -- Hộp xác nhận dùng chung (đóng UI, khôi phục mặc định)
    local confirmYesFn = nil
    local Overlay = make("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.25, BorderSizePixel = 0, Visible = false, ZIndex = 50 }, MainFrame)
    local CCard = make("Frame", { Size = UDim2.new(1, -32, 0, 140), Position = UDim2.new(0, 16, 0.5, -70),
        BackgroundColor3 = THEME.CARD, BorderSizePixel = 0, ZIndex = 51 }, Overlay)
    corner(14, CCard)
    stroke(THEME.HEADER_2, 2, CCard)
    local CTitle = text(CCard, { Position = UDim2.new(0, 12, 0, 10), Size = UDim2.new(1, -24, 0, 24), Font = Enum.Font.GothamBold,
        Text = "", TextColor3 = THEME.TEXT_MAIN, TextSize = 15, ZIndex = 52 })
    local CText = text(CCard, { Position = UDim2.new(0, 12, 0, 36), Size = UDim2.new(1, -24, 0, 52), Text = "", TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 52 })
    local CYes = make("TextButton", { Position = UDim2.new(0, 12, 1, -46), Size = UDim2.new(0.5, -18, 0, 34), BackgroundColor3 = THEME.BTN_CLOSE,
        BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = "OK", TextColor3 = THEME.WHITE, TextSize = 13, ZIndex = 52 }, CCard)
    local CNo = make("TextButton", { Position = UDim2.new(0.5, 6, 1, -46), Size = UDim2.new(0.5, -18, 0, 34), BackgroundColor3 = THEME.BTN_OFF,
        BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = "Hủy", TextColor3 = THEME.TEXT_MAIN, TextSize = 13, ZIndex = 52 }, CCard)
    corner(9, CYes)
    corner(9, CNo)
    local function askConfirm(title, body, yesText, fn)
        CTitle.Text, CText.Text, CYes.Text, confirmYesFn = title, body, yesText, fn
        Overlay.Visible = true
    end
    onClick(CNo, function() Overlay.Visible = false confirmYesFn = nil end)
    onClick(CYes, function()
        Overlay.Visible = false
        local fn = confirmYesFn
        confirmYesFn = nil
        if fn then fn() end
    end)

    -- ---------- Trang HOP ----------
    local pgHop = newPage("hop")
    local cNow = addCard(pgHop)
    ui.now = text(addRow(cNow, 22), { Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.GothamBold, Text = "👥 …", TextColor3 = THEME.TEXT_MAIN, TextSize = 16 })
    local jid = tostring(game.JobId)
    if jid == "" then jid = "(không có — Studio?)" end
    text(addRow(cNow, 16), { Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.Code, TextSize = 11,
        Text = "Mã server: " .. jid:sub(1, 26) .. (#jid > 26 and "…" or ""), TextTruncate = Enum.TextTruncate.AtEnd })

    local cLive = addCard(pgHop)
    addTitle(cLive, "TRẠNG THÁI")
    local barRow = addRow(cLive, 8)
    local barBg = make("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = THEME.BG, BorderSizePixel = 0 }, barRow)
    corner(4, barBg)
    ui.liveFill = make("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = THEME.ACCENT, BorderSizePixel = 0 }, barBg)
    corner(4, ui.liveFill)
    ui.liveStats = text(addRow(cLive, 28), { Size = UDim2.new(1, 0, 1, 0), TextSize = 11, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
    ui.status = text(addRow(cLive, 58), { Size = UDim2.new(1, 0, 1, 0), Text = "Sẵn sàng.", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })

    local cThr = addCard(pgHop)
    local function getThreshold(silent)
        local n = tonumber((ui.maxBox.Text:gsub("[^%d]", "")))
        if not n then
            if not silent then setStatus("Số người không hợp lệ — hãy nhập một số (ví dụ: 1).", THEME.ERR) end
            return nil
        end
        n = math.clamp(math.floor(n), 1, 200)
        if settings.threshold ~= n then settings.threshold = n invalidateCache() saveSoon() end
        if not silent then ui.maxBox.Text = tostring(n) end
        return n
    end
    ui.maxBox = addField(cThr, "Hop khi server có NHIỀU HƠN (người). Tìm server ≤ số này:", tostring(settings.threshold),
        function() getThreshold(false) end)
    ui.syncers[#ui.syncers + 1] = function() ui.maxBox.Text = tostring(settings.threshold) end

    local mainBtns = addButtons(pgHop and addCard(pgHop), {
        { text = "🌊 Hop ngay", bg = THEME.BTN_HOP, ts = 14 }, { text = "▶ Auto Hop: TẮT", ts = 14 },
    }, 46)
    local HopBtn, AutoBtn = mainBtns[1], mainBtns[2]

    local cQuick = addCard(pgHop)
    addTitle(cQuick, "⚡ Thao tác nhanh")
    local quickScan, saveFavoriteNow, ignoreCurrentNow, enterFirstFavorite
    addButtons(cQuick, {
        { text = "🔍 Quét thử\n(không hop)", cb = function() quickScan(false) end },
        { text = "⭐ Lưu server\nhiện tại", cb = function() saveFavoriteNow() end },
        { text = "🚫 Bỏ qua server\nhiện tại", cb = function() ignoreCurrentNow() end },
    }, 40)
    addButtons(cQuick, {
        { text = "🧹 Xóa cache", cb = function() invalidateCache() setStatus("Đã xóa cache quét.", THEME.TEXT_SUB) if ui.onCache then ui.onCache() end end },
        { text = "⭐ Vào yêu\nthích đầu", cb = function() enterFirstFavorite() end },
        { text = "📋 Xem log", cb = function() showTab("log") end },
    }, 40)

    -- ---------- Trang LỌC ----------
    local pgFil = newPage("filter")
    local cF = addCard(pgFil)
    addTitle(cF, "🎛 Lọc nâng cao (kết hợp AND)")
    intField(cF, "Số người tối thiểu", function() return settings.filter.minPlayers end, function(n) settings.filter.minPlayers = n end, 0, 200)
    intField(cF, "Chỗ trống tối thiểu", function() return settings.filter.minFree end, function(n) settings.filter.minFree = n end, 1, 200)
    intField(cF, "Ping tối đa ms (0 = tắt)", function() return settings.filter.maxPing end, function(n) settings.filter.maxPing = n end, 0, 2000)
    intField(cF, "FPS tối thiểu (0 = tắt)", function() return settings.filter.minFps end, function(n) settings.filter.minFps = n end, 0, 240)
    local selMissing = addSelect(cF, "Server thiếu ping/FPS", function()
        settings.filter.missing = (settings.filter.missing == "allow") and "reject" or "allow"
        invalidateCache() saveSoon() ui.refreshFilter()
    end)
    local selSort = addSelect(cF, "Ưu tiên chọn", function()
        local idx = 1
        for i, k in ipairs(SORT_ORDER) do if k == settings.filter.sort then idx = i end end
        settings.filter.sort = SORT_ORDER[idx % #SORT_ORDER + 1]
        invalidateCache() saveSoon() ui.refreshFilter()
    end)
    local filterNote = addNote(cF, "", 54, { TextSize = 11 })
    function ui.refreshFilter()
        selMissing.Text = MISSING_LABEL[settings.filter.missing]
        selSort.Text = SORT_LABEL[settings.filter.sort]
        local s = lastScanStats
        filterNote.Text = "Server tối đa = số ở tab Hop. Ping/FPS chỉ lọc khi API trả về số cho server đó.\n" ..
            (s and ("Lần quét gần nhất: %d/%d server có ping, %d/%d có FPS."):format(s.pingSeen, s.scanned, s.fpsSeen, s.scanned)
                or "Chưa quét — chưa biết API có trả ping/FPS không.")
    end
    ui.syncers[#ui.syncers + 1] = function() ui.refreshFilter() end
    onShow.filter = function() ui.refreshFilter() end

    local cLv = addCard(pgFil)
    addTitle(cLv, "🔎 Mức quét tối đa (1 – 10)")
    local lvSpecs = {}
    for i = 1, #SCAN_LEVELS do
        lvSpecs[i] = { text = tostring(i), ts = 12, cb = function()
            settings.scanLevel = i invalidateCache() saveSoon() ui.refreshLevel()
            setStatus(("Đã chọn mức quét %d (tối đa %d trang)."):format(i, SCAN_LEVELS[i]), THEME.TEXT_SUB)
        end }
    end
    local lvButtons = addButtons(cLv, lvSpecs, 32)
    local lvDesc = addNote(cLv, "", 44, { TextSize = 11 })
    function ui.refreshLevel()
        for i, b in ipairs(lvButtons) do styleSel(b, i == settings.scanLevel) end
        local pages = SCAN_LEVELS[settings.scanLevel]
        local p = SPEED[settings.speed]
        lvDesc.Text = ("Mức %d • tối đa %d trang (~%d server)\nLâu nhất ≈ %s ở tốc độ \"%s\". Dừng sớm khi tìm thấy.")
            :format(settings.scanLevel, pages, pages * 100, fmtTime(pages * (p.interval + p.pageDelay)), p.label)
    end
    ui.syncers[#ui.syncers + 1] = function() ui.refreshLevel() end

    -- ---------- Trang MẠNG ----------
    local pgNet = newPage("net")
    local cApi = addCard(pgNet)
    addTitle(cApi, "🌐 API lấy danh sách server")
    local apiSpecs = {}
    for i, ch in ipairs(API_CHOICES) do
        apiSpecs[i] = { text = ch.label, ts = 12, cb = function()
            settings.api = ch.key invalidateCache() saveSoon() ui.refreshApi()
            setStatus("Đã chọn API: " .. ch.label .. ".", THEME.TEXT_SUB)
        end }
    end
    local apiButtons = addButtons(cApi, apiSpecs, 32)
    local apiDesc = addNote(cApi, "", 44, { TextSize = 11 })
    function ui.refreshApi()
        for i, b in ipairs(apiButtons) do
            local on = API_CHOICES[i].key == settings.api
            styleSel(b, on)
            if on then apiDesc.Text = API_CHOICES[i].desc end
        end
    end
    ui.syncers[#ui.syncers + 1] = function() ui.refreshApi() end

    local cSp = addCard(pgNet)
    addTitle(cSp, "⏱ Tốc độ quét")
    local spSpecs = {}
    for i, k in ipairs(SPEED_ORDER) do
        spSpecs[i] = { text = SPEED[k].label, ts = 12, cb = function()
            settings.speed = k saveSoon() ui.refreshSpeed() ui.refreshLevel()
        end }
    end
    local spButtons = addButtons(cSp, spSpecs, 32)
    local spDesc = addNote(cSp, "", 44, { TextSize = 11 })
    function ui.refreshSpeed()
        for i, b in ipairs(spButtons) do styleSel(b, SPEED_ORDER[i] == settings.speed) end
        local p = SPEED[settings.speed]
        spDesc.Text = ("Cách nhau ≥ %ds/yêu cầu, tối đa %d yêu cầu/phút. Tự giảm tốc khi gặp 429/5xx (hiện ×%.1f) và nghỉ khi bị giới hạn.")
            :format(p.interval, p.perMin, net.penalty)
    end
    ui.syncers[#ui.syncers + 1] = function() ui.refreshSpeed() end

    local cNet = addCard(pgNet)
    addTitle(cNet, "📶 Tình trạng mạng (từ request thật)")
    local netLine = text(addRow(cNet, 18), { Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.GothamBold, TextColor3 = THEME.TEXT_MAIN, TextSize = 12, Text = "" })
    local netDetail = addNote(cNet, "", 30, { TextSize = 11 })
    ui.onNet = function()
        local a, b = netSummary()
        netLine.Text, netDetail.Text = a, b
        if ui.refreshSpeed then ui.refreshSpeed() end
    end

    local cCa = addCard(pgNet)
    addTitle(cCa, "🗂 Cache (chỉ trong bộ nhớ, không lưu file)")
    local caInfo = addNote(cCa, "", 44, { TextSize = 11 })
    local ttlSpecs = {}
    for i, ttl in ipairs(TTL_CHOICES) do
        ttlSpecs[i] = { text = ttl .. "s", ts = 12, cb = function() settings.cacheTTL = ttl saveSoon() ui.onCache() end }
    end
    local ttlButtons = addButtons(cCa, ttlSpecs, 30)
    addButtons(cCa, {
        { text = "🧹 Xóa cache", cb = function() invalidateCache() ui.onCache() setStatus("Đã xóa cache quét.", THEME.TEXT_SUB) end },
        { text = "🔄 Quét làm mới", bg = THEME.BTN_HOP, cb = function() quickScan(true) end },
    }, 34)
    ui.onCache = function()
        for i, b in ipairs(ttlButtons) do styleSel(b, TTL_CHOICES[i] == settings.cacheTTL) end
        local e = cache.entry
        if e and cacheValid(e, e.key, settings.cacheTTL, now()) then
            caInfo.Text = ("Đang có %d server phù hợp • tuổi %ds • còn hạn %ds (TTL %ds)")
                :format(#e.candidates, math.floor(now() - e.at), math.ceil(settings.cacheTTL - (now() - e.at)), settings.cacheTTL)
        elseif e then
            caInfo.Text = "Cache đã hết hạn (TTL " .. settings.cacheTTL .. "s) — lần Hop tới sẽ quét lại."
        else
            caInfo.Text = "Cache trống. Đổi bộ lọc/API/mức quét sẽ tự làm cache cũ không còn dùng."
        end
    end
    ui.syncers[#ui.syncers + 1] = function() ui.onCache() end
    onShow.net = function() ui.onNet() ui.onCache() ui.refreshSpeed() end

    -- ---------- Trang SERVER (yêu thích + bỏ qua) ----------
    local pgSrv = newPage("srv")
    local cFav = addCard(pgSrv)
    addTitle(cFav, "⭐ Server yêu thích (game hiện tại)")
    addNote(cFav, "ID server chỉ còn hiệu lực khi server còn người — mục có thể hết hạn. Server báo đã đóng sẽ tự bị xóa.", 42, { TextSize = 11 })
    addButtons(cFav, {
        { text = "⭐ Lưu server hiện tại", bg = THEME.BTN_HOP, cb = function() saveFavoriteNow() end },
        { text = "🗑 Xóa tất cả", cb = function() store.favorites = {} saveSoon() ui.rebuildFav() end },
    }, 34)
    local favList = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        LayoutOrder = nextOrder(cFav) }, cFav)
    make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, favList)

    local cIg = addCard(pgSrv)
    addTitle(cIg, "🚫 Danh sách bỏ qua")
    addNote(cIg, "Tự thêm khi server lỗi (5 phút) hoặc đã thử ≥3 lần (30 phút). Thêm tay = 60 phút. Hết hạn tự gỡ.", 42, { TextSize = 11 })
    addButtons(cIg, {
        { text = "🚫 Bỏ qua server hiện tại", bg = THEME.BTN_HOP, cb = function() ignoreCurrentNow() end },
        { text = "🗑 Xóa tất cả", cb = function() store.ignore = {} saveSoon() ui.rebuildIgnore() end },
    }, 34)
    local igList = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        LayoutOrder = nextOrder(cIg) }, cIg)
    make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, igList)

    local function clearList(frame)
        for _, ch in ipairs(frame:GetChildren()) do
            if ch:IsA("Frame") then ch:Destroy() end
        end
    end
    local function listRow(parent, order, labelText, btns)
        local r = make("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = order }, parent)
        text(r, { Size = UDim2.new(1, -(#btns * 52), 1, 0), Text = labelText, TextSize = 11, TextWrapped = true, TextColor3 = THEME.TEXT_MAIN })
        for i, bt in ipairs(btns) do
            local b = make("TextButton", { Position = UDim2.new(1, -(#btns - i + 1) * 52 + 2, 0, 2), Size = UDim2.new(0, 48, 1, -4),
                BackgroundColor3 = bt.bg or THEME.BTN_SMALL, BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = bt.text,
                TextColor3 = THEME.WHITE, TextSize = 11 }, r)
            corner(7, b)
            onClick(b, bt.cb)
        end
    end
    local enterFavorite
    function ui.rebuildFav()
        clearList(favList)
        local shown, others = 0, 0
        for _, e in ipairs(store.favorites) do
            if e.place == PlaceId then
                shown = shown + 1
                local age = math.max(0, nowSec() - e.savedAt)
                local warn = (e.fails or 0) >= 1 and " ⚠" or ""
                listRow(favList, shown, ("%s • %d/%d người • %s trước%s"):format(e.label ~= "" and e.label or e.id:sub(1, 8),
                    e.players, e.maxPlayers, fmtTime(age), warn), {
                    { text = "Vào", bg = THEME.BTN_HOP, cb = function() enterFavorite(e) end },
                    { text = "✕", bg = THEME.BTN_CLOSE, cb = function() favRemove(store.favorites, e.id) saveSoon() ui.rebuildFav() end },
                })
            else
                others = others + 1
            end
        end
        if shown == 0 then
            listRow(favList, 1, others > 0 and ("Chưa có mục cho game này (%d mục của game khác)."):format(others) or "Chưa có server yêu thích.", {})
        end
    end
    function ui.rebuildIgnore()
        clearList(igList)
        ignorePrune(store.ignore, nowSec())
        local arr = ignoreToArray(store.ignore, nowSec())
        for i = 1, math.min(#arr, 8) do
            local e = arr[i]
            listRow(igList, i, ("%s • %s • còn %s • %d lần"):format(e.id:sub(1, 8), e.reason, fmtTime(e.exp - nowSec()), e.count), {
                { text = "Gỡ", cb = function() store.ignore[e.id] = nil saveSoon() ui.rebuildIgnore() end },
            })
        end
        if #arr == 0 then listRow(igList, 1, "Danh sách trống.", {}) end
        if #arr > 8 then listRow(igList, 9, ("… và %d mục nữa"):format(#arr - 8), {}) end
    end
    ui.syncers[#ui.syncers + 1] = function() ui.rebuildFav() ui.rebuildIgnore() end
    onShow.srv = function() ui.rebuildFav() ui.rebuildIgnore() end

    -- ---------- Trang LỊCH ----------
    local pgSch = newPage("sch")
    local cSc = addCard(pgSch)
    addTitle(cSc, "⏰ Hẹn giờ Auto Hop")
    local schToggle = addButtons(cSc, { { text = "", ts = 13 } }, 34)[1]
    local ensureScheduler
    onClick(schToggle, function()
        settings.schedule.enabled = not settings.schedule.enabled
        saveSoon() ui.refreshSched() ensureScheduler()
    end)
    local function timeField(label, key)
        local box
        box = addField(cSc, label, settings.schedule[key], function(txt)
            txt = txt:gsub("%s", "")
            if txt == "" then settings.schedule[key] = ""
            else
                local m = parseHHMM(txt)
                if not m then
                    box.Text = settings.schedule[key]
                    setStatus("Giờ phải dạng HH:MM (ví dụ 21:30).", THEME.WAIT)
                    return
                end
                settings.schedule[key] = ("%02d:%02d"):format(math.floor(m / 60), m % 60)
            end
            box.Text = settings.schedule[key]
            saveSoon() ui.refreshSched()
        end)
        ui.syncers[#ui.syncers + 1] = function() box.Text = settings.schedule[key] end
    end
    timeField("Bật Auto lúc (HH:MM, trống = không)", "start")
    timeField("Tắt Auto lúc (HH:MM, trống = không)", "stop")
    intField(cSc, "Giới hạn mỗi lần bật (phút, 0 = không)", function() return settings.schedule.limitMin end,
        function(n) settings.schedule.limitMin = n end, 0, 1440)
    local schInfo = addNote(cSc, "", 64, { TextSize = 11 })
    function ui.refreshSched()
        local s = settings.schedule
        schToggle.Text = s.enabled and "⏰ Lịch: BẬT" or "⏰ Lịch: TẮT"
        schToggle.BackgroundColor3 = s.enabled and THEME.BTN_ON or THEME.BTN_OFF
        local d = os.date("*t")
        local ran = (autoEnabled and settings.autoStartedAt > 0) and ("Auto đã chạy %s."):format(fmtTime(nowSec() - settings.autoStartedAt)) or "Auto đang tắt."
        schInfo.Text = ("Giờ thiết bị: %02d:%02d • %s\nChỉ chạy khi script còn hoạt động (cần autoexec để giữ qua teleport). Mỗi mốc giờ chỉ kích hoạt 1 lần/phút."):format(d.hour, d.min, ran)
    end
    ui.syncers[#ui.syncers + 1] = function() ui.refreshSched() end
    onShow.sch = function() ui.refreshSched() end

    -- ---------- Trang LOG ----------
    local pgLog = newPage("log")
    local cLog = addCard(pgLog)
    addTitle(cLog, "📋 Nhật ký lỗi (trong bộ nhớ, tối đa " .. CONFIG.LOG_MAX .. ")")
    addButtons(cLog, {
        { text = "🗑 Xóa log", cb = function() errlog = {} renderLog() end },
        { text = "📤 Sao chép", bg = THEME.BTN_HOP, cb = function()
            if #errlog == 0 then setStatus("Log đang trống.", THEME.TEXT_SUB) return end
            local ok, how = copyText(ui.logText.Text, "wx_hub_log.txt")
            setStatus(ok and ("Đã xuất log → " .. how) or "Executor không hỗ trợ clipboard/ghi file — hãy chép tay.", ok and THEME.OK or THEME.WAIT)
        end },
    }, 34)
    local logRow = make("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = nextOrder(cLog) }, cLog)
    ui.logText = text(logRow, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextSize = 11, TextWrapped = true,
        TextYAlignment = Enum.TextYAlignment.Top, Text = "Chưa có lỗi nào được ghi." })
    onShow.log = renderLog

    -- ---------- Trang TOOLS ----------
    local pgTool = newPage("tool")
    local cSave = addCard(pgTool)
    addTitle(cSave, "💾 Lưu cấu hình")
    addNote(cSave, canSave and ("Đang lưu tự động vào " .. SAVE_FILE .. " (cài đặt, yêu thích, danh sách bỏ qua).")
        or "Executor này KHÔNG hỗ trợ writefile/readfile — cài đặt chỉ giữ trong phiên, mất khi thoát/teleport. Dùng Xuất JSON để tự lưu.",
        44, { TextSize = 11, TextColor3 = canSave and THEME.TEXT_SUB or THEME.WAIT })
    if loadNote then addNote(cSave, loadNote, 18, { TextSize = 11, TextColor3 = THEME.ERR }) end

    local cIO = addCard(pgTool)
    addTitle(cIO, "🔁 Nhập / Xuất JSON")
    local ioBox = make("TextBox", { Size = UDim2.new(1, 0, 0, 80), BackgroundColor3 = THEME.BG, BorderSizePixel = 0, Font = Enum.Font.Code,
        Text = "", PlaceholderText = "Dán JSON cấu hình vào đây rồi bấm Nhập…", TextColor3 = THEME.TEXT_MAIN, TextSize = 11,
        TextWrapped = true, MultiLine = true, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = nextOrder(cIO) }, cIO)
    corner(8, ioBox)
    stroke(THEME.CARD_STROKE, 1, ioBox)
    local syncUI
    local function importFromString(raw)
        if type(raw) ~= "string" or raw:match("^%s*$") then setStatus("Chưa có dữ liệu để nhập.", THEME.WAIT) return end
        if #raw > CONFIG.MAX_IMPORT_BYTES then
            logError("import", "size", "vượt " .. CONFIG.MAX_IMPORT_BYTES .. " byte")
            setStatus("Dữ liệu quá lớn (> " .. CONFIG.MAX_IMPORT_BYTES .. " byte).", THEME.ERR)
            return
        end
        local okJ, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if not okJ then
            logError("import", "json", data)
            setStatus("Không đọc được JSON — kiểm tra dấu ngoặc/dấu phẩy.", THEME.ERR)
            return
        end
        local ok, out, errs, warns = validateConfig(data)
        if not ok then
            logError("import", "invalid", errs[1])
            setStatus(("Nhập thất bại (%d lỗi), chưa áp dụng gì:\n%s"):format(#errs, table.concat(errs, "; "):sub(1, 150)), THEME.ERR)
            return
        end
        out.auto, out.autoStartedAt = nil, nil -- nhập không bao giờ tự bật Auto Hop
        applyConfig(out, false)
        invalidateCache()
        syncUI()
        saveSoon()
        setStatus("Đã nhập cấu hình hợp lệ." .. (#warns > 0 and ("\n" .. table.concat(warns, "; ")) or ""), THEME.OK)
    end
    addButtons(cIO, {
        { text = "📤 Xuất", bg = THEME.BTN_HOP, cb = function()
            local json = HttpService:JSONEncode(snapshot(false))
            ioBox.Text = json
            local ok, how = copyText(json, "wx_hub_export.json")
            setStatus(ok and ("Đã xuất JSON → " .. how) or "Đã hiện JSON trong ô — executor không có clipboard/ghi file, hãy chép tay.", ok and THEME.OK or THEME.WAIT)
        end },
        { text = "📥 Nhập từ ô", cb = function() importFromString(ioBox.Text) end },
        { text = "📂 Nhập file", cb = function()
            if not canSave then setStatus("Executor không hỗ trợ đọc file — dùng ô dán JSON.", THEME.WAIT) return end
            local okE, ex = pcall(isfile, "wx_hub_import.json")
            if not (okE and ex) then setStatus("Không thấy file wx_hub_import.json trong thư mục workspace.", THEME.WAIT) return end
            local okR, raw = pcall(readfile, "wx_hub_import.json")
            if not okR then logError("save", "read", raw) setStatus("Không đọc được file.", THEME.ERR) return end
            importFromString(raw)
        end },
    }, 34)

    local cUi = addCard(pgTool)
    addTitle(cUi, "📱 Giao diện & khôi phục")
    local compactBtn = addButtons(cUi, { { text = "" } }, 34)[1]
    local function refreshCompact() compactBtn.Text = settings.compact and "📱 Giao diện gọn: BẬT" or "📱 Giao diện gọn: tự động" styleSel(compactBtn, settings.compact) end
    local applyLayout
    onClick(compactBtn, function() settings.compact = not settings.compact saveSoon() refreshCompact() applyLayout() end)
    ui.syncers[#ui.syncers + 1] = function() refreshCompact() end
    addNote(cUi, "Tự thu gọn khi màn hình thấp (điện thoại ngang). Bật tay để ép bố cục gọn.", 30, { TextSize = 11 })
    local setAuto
    addButtons(cUi, { { text = "♻ Khôi phục mặc định", bg = THEME.BTN_CLOSE, cb = function()
        askConfirm("♻ Khôi phục mặc định?", "Đặt lại mọi cài đặt (lọc, API, tốc độ, lịch…). Server yêu thích và danh sách bỏ qua được GIỮ nguyên.", "Khôi phục", function()
            setAuto(false, false)
            settings = deepcopy(DEFAULTS)
            invalidateCache()
            syncUI()
            saveNow()
            setStatus("Đã khôi phục cài đặt mặc định.", THEME.OK)
        end)
    end } }, 34)

    local cTest = addCard(pgTool)
    addTitle(cTest, "🧪 Self-Test (không teleport, không đổi cài đặt)")
    local runSelfTest
    addButtons(cTest, { { text = "▶ Chạy Self-Test", bg = THEME.BTN_HOP, cb = function() runSelfTest() end } }, 34)
    local testOut = addNote(cTest, "Kiểm thử logic bằng dữ liệu giả lập: lọc, cấu hình, hẹn giờ, giới hạn tốc độ, cache, quét nhiều trang, guard, dry-run teleport.", 56, { TextSize = 11 })

    -- ---------- Cửa sổ: layout, kéo, thu nhỏ ----------
    applyLayout = function()
        local m = metrics()
        ui.m = m
        local hh = m.compact and 44 or 60
        Header.Size = UDim2.new(1, 0, 0, hh)
        ui.sub.Visible = not m.compact
        ui.title.Position = UDim2.new(0, 12, 0, m.compact and 9 or 8)
        MinBtn.Position = UDim2.new(1, -68, 0, (hh - 28) / 2)
        CloseBtn.Position = UDim2.new(1, -36, 0, (hh - 28) / 2)
        ui.body.Position = UDim2.new(0, 8, 0, hh + 6)
        ui.body.Size = UDim2.new(1, -16, 1, -(hh + 12))
        local height = ui.minimized and hh or m.H
        MainFrame.Size = UDim2.new(0, m.W, 0, height)
        local vx, vy = viewport()
        local p = MainFrame.Position
        MainFrame.Position = UDim2.new(0, math.clamp(p.X.Offset, 0, math.max(0, vx - m.W)), 0, math.clamp(p.Y.Offset, 0, math.max(0, vy - height)))
    end
    do
        local vx, vy = viewport()
        local m = metrics()
        MainFrame.Position = UDim2.new(0, math.max(0, (vx - m.W) / 2), 0, math.max(0, (vy - m.H) / 2))
    end
    applyLayout()
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(function() task.defer(applyLayout) end) end
    end)

    do -- kéo cửa sổ: chỉ từ thanh tiêu đề (để cuộn trang không làm di chuyển cửa sổ)
        local dragging, dragStart, startPos = false, nil, nil
        Header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging, dragStart, startPos = true, input.Position, MainFrame.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end)
        UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local d = input.Position - dragStart
                local vx, vy = viewport()
                local h = MainFrame.AbsoluteSize.Y
                MainFrame.Position = UDim2.new(0, math.clamp(startPos.X.Offset + d.X, 0, math.max(0, vx - ui.m.W)),
                    0, math.clamp(startPos.Y.Offset + d.Y, 0, math.max(0, vy - h)))
            end
        end)
    end
    onClick(MinBtn, function()
        ui.minimized = not ui.minimized
        ui.body.Visible = not ui.minimized
        MinBtn.Text = ui.minimized and "+" or "–"
        applyLayout()
    end)

    -- =================== LOGIC ===================
    local function playerCount() return #Players:GetPlayers() end
    local function refreshNow()
        ui.now.Text = ("👥 Server hiện tại: %d / %d người"):format(playerCount(), Players.MaxPlayers)
    end
    Players.PlayerAdded:Connect(refreshNow)
    Players.PlayerRemoving:Connect(function() task.defer(refreshNow) end)

    local function updateBusyUI()
        local o = guard.owner
        if o == "scan" then
            HopBtn.Text, HopBtn.BackgroundColor3, HopBtn.Active = "⏹ Hủy quét", THEME.BTN_CLOSE, true
        elseif o then
            HopBtn.Text, HopBtn.BackgroundColor3, HopBtn.Active = (o == "teleport") and "… Đang teleport" or "… Đang bận", THEME.BTN_OFF, false
        else
            HopBtn.Text, HopBtn.BackgroundColor3, HopBtn.Active = "🌊 Hop ngay", THEME.BTN_HOP, true
        end
    end
    guard.onChange = updateBusyUI

    -- Chạy một tác vụ có giữ khoá guard; lỗi bất ngờ luôn nhả khoá
    local function withGuard(owner, fn)
        local token, why = guardAcquire(owner)
        if not token then return nil, why end
        local res = table.pack(pcall(fn, token))
        if not res[1] then
            guardRelease(token)
            logError("ui", "exception", res[2])
            setStatus("Lỗi nội bộ: " .. tostring(res[2]):sub(1, 100), THEME.ERR)
            return nil, tostring(res[2])
        end
        return res[2], res[3]
    end

    local function markFail(id)
        if not id then return end
        local c = attempts[id] or 1
        if c >= 3 then ignoreAdd(store.ignore, id, "attempts", CONFIG.IGNORE_ATTEMPT_TTL, nowSec(), c)
        else ignoreAdd(store.ignore, id, "auto", CONFIG.IGNORE_AUTO_TTL, nowSec(), c) end
        saveSoon()
        if ui.tab == "srv" then ui.rebuildIgnore() end
    end

    -- Kiểm tra trước teleport (chống trùng / sai trạng thái)
    local function preflight(id, recent, t, lastAt)
        if type(id) ~= "string" or id == "" then return false, "ID server không hợp lệ" end
        if id == tostring(game.JobId) then return false, "Đây đã là server hiện tại" end
        if LocalPlayer.Parent ~= Players then return false, "Người chơi không còn trong game" end
        local r = recent[id]
        if r and (t - r) < CONFIG.RECENT_TARGET_TTL then return false, "Server này vừa được thử — chờ ít giây" end
        if teleportStarted then return false, "Đang có teleport diễn ra" end
        if (t - lastAt) < CONFIG.MIN_TELEPORT_GAP then return false, "Teleport quá dày — chờ vài giây" end
        return true
    end

    local function safeTeleport(id, token, kind, dry)
        local ok, why = preflight(id, recentTargets, now(), lastTeleportAt)
        if not ok then return false, why end
        if dry then return true, "dry-run" end
        guardSet(token, "teleport")
        lastTargetId, lastTeleportKind = id, kind
        lastTeleportAt = now()
        recentTargets[id] = now()
        attempts[id] = (attempts[id] or 0) + 1
        teleportGen = teleportGen + 1
        teleportStarted = false
        local myTp = teleportGen
        saveNow() -- lưu trước khi rời server để Auto Hop có thể tiếp tục
        local okT, err = pcall(function() TeleportService:TeleportToPlaceInstance(PlaceId, id, LocalPlayer) end)
        if not okT then
            logError("teleport", "exception", err)
            markFail(id)
            return false, tostring(err):sub(1, 100)
        end
        task.delay(CONFIG.TELEPORT_TIMEOUT, function()
            if running and teleportGen == myTp and guard.token == token and guard.owner == "teleport" then
                if not teleportStarted then markFail(id) end
                guardRelease(token)
                teleportStarted = false
                invalidateCache()
                setStatus(teleportStarted and "Teleport đang xử lý lâu — thử lại sau." or
                    ("Teleport không phản hồi sau %ds — đã bỏ qua server này. Bấm Hop ngay để thử lại."):format(CONFIG.TELEPORT_TIMEOUT), THEME.ERR)
            end
        end)
        return true
    end

    pcall(function()
        LocalPlayer.OnTeleport:Connect(function(state)
            if state ~= Enum.TeleportState.Failed then teleportStarted = true end
        end)
    end)

    local hopOnce
    TeleportService.TeleportInitFailed:Connect(guarded(function(plr, result, message)
        if plr ~= LocalPlayer then return end
        teleportGen = teleportGen + 1
        teleportStarted = false
        guardRelease(guard.token)
        if lastHopFromAuto then autoFailureCount = autoFailureCount + 1 end
        local detail = (message and tostring(message) ~= "") and (" — " .. tostring(message)) or ""
        logError("teleport", result, detail)
        local name = tostring(result):match("(%w+)$") or tostring(result)
        if result == Enum.TeleportResult.IsTeleporting then
            setStatus("Roblox đang teleport sẵn một lần khác — chờ rồi bấm lại." .. detail, THEME.WAIT)
            return
        end
        markFail(lastTargetId)
        cache.entry = nil
        if lastTeleportKind == "fav" then
            if name == "GameEnded" or name == "GameNotFound" then
                favRemove(store.favorites, lastTargetId)
                saveSoon() ui.rebuildFav()
                setStatus("Server yêu thích đã đóng — đã xóa khỏi danh sách.", THEME.ERR)
            else
                for _, e in ipairs(store.favorites) do if e.id == lastTargetId then e.fails = (e.fails or 0) + 1 end end
                setStatus("Không vào được server yêu thích: " .. classifyTeleport(result), THEME.ERR)
            end
            return
        end
        if hopRetryCount < CONFIG.MAX_HOP_RETRY then
            hopRetryCount = hopRetryCount + 1
            local delaySec = (name == "Flooded") and 8 or 2
            setStatus(("Roblox từ chối (%s).\nThử server khác (%d/%d) sau %ds…"):format(classifyTeleport(result), hopRetryCount, CONFIG.MAX_HOP_RETRY, delaySec), THEME.WAIT)
            task.delay(delaySec, function()
                if running and ScreenGui.Parent and not guard.owner then hopOnce(lastHopFromAuto, true) end
            end)
        else
            hopRetryCount = 0
            setStatus(("Đã thử %d server nhưng đều bị từ chối (%s).\nThử Quét làm mới hoặc đổi bộ lọc."):format(CONFIG.MAX_HOP_RETRY, classifyTeleport(result)), THEME.ERR)
        end
    end))

    local function failOut(token, fromAuto, msg, color, phase)
        guardRelease(token)
        if fromAuto then autoFailureCount = autoFailureCount + 1 end
        liveSet({ phase = phase or "error" })
        setStatus(msg, color)
        return false
    end

    -- Hop 1 lần (dùng chung cho tay / Auto / thử lại)
    hopOnce = function(fromAuto, isRetry)
        local threshold = getThreshold(fromAuto)
        if not threshold then return false end
        if guard.owner then
            if not fromAuto then setStatus("Đang bận (" .. guard.owner .. ") — chờ xong rồi thử lại.", THEME.WAIT) end
            return false
        end
        if not isRetry then
            hopRetryCount = 0
            local remain = CONFIG.HOP_COOLDOWN - (now() - lastHopAttempt)
            if remain > 0 then
                if fromAuto then task.wait(remain)
                else setStatus(("Vừa hop xong — chờ khoảng %.0fs nữa nhé."):format(remain), THEME.WAIT) return false end
            end
        end
        local count = playerCount()
        if count <= threshold then
            setStatus(("✓ Server hiện tại %d người (≤ %d) — không cần hop."):format(count, threshold), THEME.OK)
            return false
        end
        local res, why = withGuard("scan", function(token)
            lastHopFromAuto, lastHopAttempt = fromAuto and true or false, now()
            setStatus(("Server hiện tại %d người — đang tìm server ≤ %d người…"):format(count, threshold), THEME.WAIT)
            local autoNote = fromAuto and ("\nAuto Hop kiểm tra lại sau " .. CONFIG.AUTO_CHECK_INTERVAL .. "s.") or ""
            local candidates, err, scanned, stopInfo = scanServers(threshold)
            if guard.cancel then return failOut(token, false, "Đã hủy quét.", THEME.TEXT_SUB, "cancel") end
            if not candidates then return failOut(token, fromAuto, "Lỗi lấy danh sách server: " .. tostring(err) .. autoNote, THEME.ERR) end
            local best = pickCandidate(candidates, store.ignore, recentTargets, nowSec())
            if not best and #candidates > 0 then
                invalidateCache()
                candidates, err, scanned, stopInfo = scanServers(threshold)
                if candidates then best = pickCandidate(candidates, store.ignore, recentTargets, nowSec()) end
            end
            if not best then
                return failOut(token, fromAuto, ("Không tìm thấy server phù hợp (đã quét %d server, mức %d).%s\nThử nới bộ lọc, tăng mức quét hoặc giới hạn người.")
                    :format(scanned or 0, settings.scanLevel, stopInfo and ("\n" .. stopInfo) or "") .. autoNote, THEME.WAIT, "done")
            end
            liveSet({ phase = "teleport" })
            setStatus(("🎯 Chọn server %d/%d người (quét %d server) — đang hop…"):format(best.playing, best.maxPlayers, scanned or 0), THEME.ACCENT)
            local ok, terr = safeTeleport(best.id, token, "hop", false)
            if ok then
                setStatus(("Đang chuyển tới server %d/%d người… 🌊"):format(best.playing, best.maxPlayers), THEME.OK)
                return true
            end
            return failOut(token, fromAuto, "Không teleport được: " .. tostring(terr) .. autoNote, THEME.ERR)
        end)
        if res == nil and why and not guard.owner then setStatus(tostring(why), THEME.WAIT) end
        return res == true
    end

    quickScan = function(force)
        local threshold = getThreshold(false)
        if not threshold then return end
        local _, why = withGuard("scan", function(token)
            setStatus("Quét thử (không teleport)…", THEME.WAIT)
            local candidates, err, scanned, stopInfo, meta = scanServers(threshold, { force = force })
            guardRelease(token)
            if guard.cancel then return end
            if not candidates then setStatus("Lỗi quét: " .. tostring(err), THEME.ERR) return end
            setStatus(("Quét thử xong: %d server phù hợp / %d đã quét%s.%s"):format(#candidates, scanned or 0,
                (meta and meta.fromCache) and " (từ cache)" or "", stopInfo and ("\n" .. stopInfo) or ""),
                #candidates > 0 and THEME.OK or THEME.WAIT)
            if ui.onCache then ui.onCache() end
            ui.refreshFilter()
        end)
        if why then setStatus(tostring(why), THEME.WAIT) end
    end

    saveFavoriteNow = function()
        local id = tostring(game.JobId)
        if not validId(id) then setStatus("Không có JobId hợp lệ (đang ở Studio?).", THEME.WAIT) return end
        local entry = { id = id, place = PlaceId, label = "Server " .. id:sub(1, 6), players = playerCount(),
            maxPlayers = Players.MaxPlayers, savedAt = nowSec(), fails = 0 }
        local ok, why = favAdd(store.favorites, entry, CONFIG.MAX_FAVORITES)
        setStatus(ok and "⭐ Đã lưu server hiện tại vào yêu thích." or ("Không lưu được: " .. why), ok and THEME.OK or THEME.WAIT)
        if ok then saveSoon() ui.rebuildFav() end
    end

    ignoreCurrentNow = function()
        local id = tostring(game.JobId)
        if not validId(id) then setStatus("Không có JobId hợp lệ (đang ở Studio?).", THEME.WAIT) return end
        ignoreAdd(store.ignore, id, "manual", CONFIG.IGNORE_MANUAL_TTL, nowSec(), 1)
        saveSoon()
        setStatus("🚫 Đã bỏ qua server này trong " .. fmtTime(CONFIG.IGNORE_MANUAL_TTL) .. ".", THEME.OK)
        if ui.tab == "srv" then ui.rebuildIgnore() end
    end

    enterFavorite = function(e)
        local _, why = withGuard("scan", function(token)
            local ok, err = safeTeleport(e.id, token, "fav", false)
            if ok then setStatus("Đang vào server yêu thích " .. (e.label or "") .. "… 🌊", THEME.OK) return true end
            guardRelease(token)
            setStatus("Không vào được: " .. tostring(err), THEME.WAIT)
        end)
        if why then setStatus(tostring(why), THEME.WAIT) end
    end
    enterFirstFavorite = function()
        for _, e in ipairs(store.favorites) do
            if e.place == PlaceId then enterFavorite(e) return end
        end
        setStatus("Chưa có server yêu thích cho game này.", THEME.WAIT)
    end

    -- Auto Hop + hẹn giờ (vòng nền chỉ chạy khi cần)
    local function updateAutoBtn()
        AutoBtn.Text = autoEnabled and "⏹ Auto Hop: BẬT" or "▶ Auto Hop: TẮT"
        AutoBtn.BackgroundColor3 = autoEnabled and THEME.BTN_ON or THEME.BTN_OFF
    end
    setAuto = function(on, resumed)
        autoEnabled = on
        autoGen = autoGen + 1
        settings.autoStartedAt = on and ((resumed and settings.autoStartedAt > 0) and settings.autoStartedAt or nowSec()) or 0
        updateAutoBtn()
        saveSoon()
        if not on then
            setStatus("Auto Hop đã TẮT.", THEME.TEXT_SUB)
            return
        end
        local gen = autoGen
        autoCycleCount, autoFailureCount = 0, 0
        if resumed then
            lastHopAttempt = now()
            setStatus("Auto Hop tự bật lại (đã lưu từ lần trước). Bấm nút để tắt.", THEME.ACCENT)
        else
            setStatus("Auto Hop BẬT — kiểm tra ngay rồi lặp mỗi " .. CONFIG.AUTO_CHECK_INTERVAL .. "s.", THEME.ACCENT)
        end
        task.spawn(function()
            while autoEnabled and gen == autoGen and running and ScreenGui.Parent do
                autoCycleCount = autoCycleCount + 1
                liveSet({ phase = "idle" })
                local okH, errH = pcall(hopOnce, true)
                if not okH then logError("ui", "exception", errH) end
                for _ = 1, CONFIG.AUTO_CHECK_INTERVAL / 5 do
                    if not autoEnabled or gen ~= autoGen or not running or not ScreenGui.Parent then break end
                    task.wait(5)
                end
            end
        end)
    end

    local schedGen, schedKey = 0, nil
    local function schedTick()
        local d = os.date("*t")
        local action, key = scheduleDecision(d.hour * 60 + d.min, nowSec(), settings.schedule, autoEnabled,
            settings.autoStartedAt, schedKey, d.yday or 0)
        schedKey = key
        if action == "start" then setAuto(true, false) setStatus("⏰ Lịch: đã bật Auto Hop.", THEME.ACCENT)
        elseif action == "stop" then setAuto(false, false) setStatus("⏰ Lịch: đã tắt Auto Hop theo giờ hẹn.", THEME.ACCENT)
        elseif action == "limit" then
            setAuto(false, false)
            setStatus(("⏰ Hết giới hạn %d phút — đã tắt Auto Hop."):format(settings.schedule.limitMin), THEME.ACCENT)
        end
        if ui.tab == "sch" then ui.refreshSched() end
    end
    ensureScheduler = function()
        schedGen = schedGen + 1
        if not settings.schedule.enabled then return end
        local gen = schedGen
        task.spawn(function()
            while running and ScreenGui.Parent and gen == schedGen and settings.schedule.enabled do
                local ok, err = pcall(schedTick)
                if not ok then logError("ui", "exception", err) end
                task.wait(CONFIG.SCHED_TICK)
            end
        end)
    end

    onClick(AutoBtn, function() setAuto(not autoEnabled, false) end)
    onClick(HopBtn, function()
        if guard.owner == "scan" then guard.cancel = true setStatus("Đang hủy quét…", THEME.WAIT)
        elseif guard.owner then setStatus("Đang xử lý — vui lòng chờ.", THEME.WAIT)
        else task.spawn(function() hopOnce(false) end) end
    end)
    onClick(CloseBtn, function()
        askConfirm("🌊 Đóng UI?", "Mở lại bằng nút 🌊. Auto Hop sẽ được tắt.", "Đóng", function()
            setAuto(false, false)
            MainFrame.Visible = false
        end)
    end)

    syncUI = function()
        for _, fn in ipairs(ui.syncers) do
            local ok, err = pcall(fn)
            if not ok then logError("ui", "exception", err) end
        end
        applyLayout()
        updateAutoBtn()
        ensureScheduler()
    end

    -- =================== SELF-TEST ===================
    local function selfTestCore()
        local results = {}
        local function add(name, fn)
            local ok, err = pcall(fn)
            results[#results + 1] = { name = name, ok = ok, err = (not ok) and tostring(err) or nil }
        end
        local function eq(a, b, m)
            if a ~= b then error((m or "eq") .. ": cần " .. tostring(b) .. ", nhận " .. tostring(a), 0) end
        end
        local function truthy(v, m) if not v then error(m or "cần giá trị đúng", 0) end end
        local T = 1000000
        local SELF = "self-job-0001"
        local function srv(id, playing, ping, fps)
            return { id = id, playing = playing, maxPlayers = 10, ping = ping, fps = fps }
        end
        local servers = { srv("srv-a1", 1, 50, 60), srv("srv-a2", 0), srv("srv-a3", 10), srv("srv-a4", 2),
            srv("srv-a5", 3, 300, 30), srv(SELF, 1), srv("srv-a7", 5) }
        local function ids(f, ign)
            local r = {}
            for _, s in ipairs(servers) do
                if passesFilter(s, 3, f, SELF, ign or {}, T) then r[#r + 1] = s.id end
            end
            table.sort(r)
            return table.concat(r, ",")
        end

        add("Lọc nâng cao: kết hợp điều kiện", function()
            local f = deepcopy(DEFAULTS.filter)
            eq(ids(f), "srv-a1,srv-a4,srv-a5", "mặc định")
            f.maxPing = 100
            eq(ids(f), "srv-a1,srv-a4", "ping+cho qua")
            f.missing = "reject"
            eq(ids(f), "srv-a1", "ping+loại thiếu")
            f.maxPing, f.missing, f.minFree = 0, "allow", 9
            eq(ids(f), "srv-a1", "chỗ trống")
            f.minFree, f.minFps = 1, 50
            eq(ids(f), "srv-a1,srv-a4", "fps")
        end)
        add("Bỏ qua: server bị ignore bị loại, hết hạn thì cho lại", function()
            local f = deepcopy(DEFAULTS.filter)
            eq(ids(f, { ["srv-a1"] = { exp = T + 100 } }), "srv-a4,srv-a5", "còn hạn")
            eq(ids(f, { ["srv-a1"] = { exp = T - 1 } }), "srv-a1,srv-a4,srv-a5", "hết hạn")
        end)
        add("Sắp xếp: ít người / ping / fps (thiếu dữ liệu xếp cuối)", function()
            local function order(mode)
                local list = { srv("srv-a5", 3, 300, 30), srv("srv-a4", 2), srv("srv-a1", 1, 50, 60) }
                sortCandidates(list, mode)
                local r = {}
                for _, s in ipairs(list) do r[#r + 1] = s.id end
                return table.concat(r, ",")
            end
            eq(order("fewest"), "srv-a1,srv-a4,srv-a5")
            eq(order("ping"), "srv-a1,srv-a5,srv-a4")
            eq(order("fps"), "srv-a1,srv-a5,srv-a4")
        end)
        add("Chọn server: bỏ ignore và server vừa thử", function()
            local c = { { id = "srv-a1", playing = 1 }, { id = "srv-a4", playing = 2 } }
            local pick = pickCandidate(c, { ["srv-a1"] = { exp = T + 5 } }, {}, T)
            eq(pick.id, "srv-a4", "ignore")
            eq(pickCandidate(c, {}, { ["srv-a1"] = T - 5, ["srv-a4"] = T - 5 }, T), nil, "vừa thử hết")
        end)
        add("Yêu thích/Ignore: thêm, trùng, đầy, xóa, giới hạn", function()
            local list = {}
            truthy(favAdd(list, { id = "fav-0001a" }, 2))
            eq((favAdd(list, { id = "fav-0001a" }, 2)), false, "trùng")
            truthy(favAdd(list, { id = "fav-0002b" }, 2))
            eq((favAdd(list, { id = "fav-0003c" }, 2)), false, "đầy")
            truthy(favRemove(list, "fav-0001a"))
            eq(#list, 1)
            local ign = {}
            ignoreAdd(ign, "x-aaaaaaaa", "auto", 10, T, 1)
            truthy(ign["x-aaaaaaaa"].exp == T + 10)
            ignorePrune(ign, T + 11)
            eq(next(ign), nil, "prune")
        end)
        add("Cấu hình: hợp lệ qua JSON khứ hồi", function()
            local data = HttpService:JSONDecode(HttpService:JSONEncode(snapshot(false)))
            local ok, out, errs = validateConfig(data)
            truthy(ok, "khứ hồi: " .. tostring(errs and errs[1]))
            eq(out.threshold, settings.threshold)
        end)
        add("Cấu hình: từ chối dữ liệu sai (mỗi ca phải bị chặn)", function()
            local cases = {
                { threshold = 0 }, { threshold = "5" }, { api = "evil" }, { scanLevel = 11 }, { speed = "turbo" },
                { cacheTTL = 5 }, { filter = { sort = "zzz" } }, { filter = { maxPing = -1 } },
                { schedule = { start = "25:99" } }, { schedule = { limitMin = 5000 } },
                { favorites = { { id = "bad id!", place = 1 } } }, { ignore = { { id = "ok-aaaaaa", exp = "x", reason = "auto" } } },
                { version = 2 }, "chuỗi", 42,
            }
            for i, c in ipairs(cases) do
                local ok = validateConfig(c)
                eq(ok, false, "ca " .. i .. " lẽ ra phải bị từ chối")
            end
            local ok, _, _, warns = validateConfig({ threshold = 3, truong_la = 1 })
            truthy(ok and #warns == 1, "trường lạ chỉ cảnh báo")
        end)
        add("Giờ hẹn: phân tích HH:MM", function()
            eq(parseHHMM("07:05"), 425)
            eq(parseHHMM("7:05"), 425)
            eq(parseHHMM("24:00"), nil)
            eq(parseHHMM("12:60"), nil)
            eq(parseHHMM("1205"), nil)
            eq(parseHHMM(""), nil)
        end)
        add("Hẹn giờ: bật/tắt/giới hạn, chỉ 1 lần mỗi phút", function()
            local s = { enabled = true, start = "08:00", stop = "09:00", limitMin = 30 }
            local a, k = scheduleDecision(480, T, s, false, 0, nil, 5)
            eq(a, "start")
            eq((scheduleDecision(480, T, s, false, 0, k, 5)), nil, "không lặp trong cùng phút")
            eq((scheduleDecision(540, T, s, true, T - 10, nil, 5)), "stop")
            eq((scheduleDecision(500, T, s, true, T - 1801, nil, 5)), "limit")
            eq((scheduleDecision(480, T, { enabled = false, start = "08:00", stop = "", limitMin = 0 }, false, 0, nil, 5)), nil, "tắt lịch")
        end)
        add("Giới hạn tốc độ: khoảng cách, ngân sách/phút, giảm tốc", function()
            eq(computeWait({ T - 1 }, T, 3, 12, 1), 2)
            eq(computeWait({ T - 1 }, T, 3, 12, 2), 5)
            local st = {}
            for i = 12, 1, -1 do st[#st + 1] = T - i end
            eq(computeWait(st, T, 3, 12, 1), 48, "chạm trần 12/phút")
            eq(computeWait({}, T, 3, 12, 1), 0)
            local p = adjustPenalty(1, "429")
            eq(p, 2)
            eq(adjustPenalty(adjustPenalty(p, "429"), "429"), 4, "trần ×4")
            local q = 4
            for _ = 1, 20 do q = adjustPenalty(q, "ok") end
            eq(q, 1, "hồi phục về ×1")
        end)
        add("Cache: TTL và khoá theo bộ lọc", function()
            local f1, f2 = deepcopy(DEFAULTS.filter), deepcopy(DEFAULTS.filter)
            f2.maxPing = 100
            local k1, k2 = cacheKey(1, 4, "roblox", f1), cacheKey(1, 4, "roblox", f2)
            truthy(k1 ~= k2, "khoá phải khác")
            local e = { key = k1, at = T }
            truthy(cacheValid(e, k1, 30, T + 29), "còn hạn")
            eq(cacheValid(e, k1, 30, T + 30), false, "hết hạn")
            eq(cacheValid(e, k2, 30, T + 1), false, "khác khoá")
            eq(cacheValid(nil, k1, 30, T), false, "trống")
        end)
        add("Quét nhiều trang bằng dữ liệu giả (phân trang, dừng sớm)", function()
            local calls = 0
            local function fetch(cursor)
                calls = calls + 1
                if cursor == nil then return { data = { srv("p1-aaaaaa", 9, 40) }, nextPageCursor = "c2" } end
                return { data = { srv("p2-bbbbbb", 1, 60, 55) }, nextPageCursor = "c3" }
            end
            local c, err, scanned, stop, meta = scanServers(3, { fetch = fetch, noCache = true, noStats = true,
                onProgress = function() end, wait = function() end })
            eq(err, nil)
            eq(#c, 1)
            eq(c[1].id, "p2-bbbbbb")
            eq(scanned, 2)
            eq(calls, 2, "dừng sau trang có kết quả")
            eq(meta.pingSeen, 2)
            eq(stop, nil)
        end)
        add("Quét: lỗi giữa chừng, trang đầu lỗi, giới hạn trang", function()
            local noop = function() end
            local function failSecond(cursor)
                if cursor == nil then return { data = { srv("p1-aaaaaa", 9) }, nextPageCursor = "c2" } end
                return nil, "boom"
            end
            local c, _, _, stop = scanServers(3, { fetch = failSecond, noCache = true, noStats = true, onProgress = noop, wait = noop })
            eq(#c, 0)
            truthy(stop and stop:find("boom"), "phải báo lỗi giữa chừng")
            local c2, err2 = scanServers(3, { fetch = function() return nil, "x" end, noCache = true, noStats = true, onProgress = noop, wait = noop })
            eq(c2, nil)
            eq(err2, "x")
            local n = 0
            local c3, _, _, stop3, meta3 = scanServers(3, { maxPages = 1, noCache = true, noStats = true, onProgress = noop, wait = noop,
                fetch = function() n = n + 1 return { data = { srv("p1-aaaaaa", 9) }, nextPageCursor = "c2" } end })
            eq(#c3, 0)
            eq(n, 1, "chỉ 1 trang")
            eq(meta3.pages, 1)
            eq(stop3, nil)
        end)
        add("Phân loại lỗi HTTP/teleport", function()
            truthy(classifyHttp(429):find("giới hạn"), "429")
            truthy(classifyHttp(503):find("máy chủ"), "5xx")
            truthy(classifyHttp("json"):find("JSON"), "json")
            truthy(classifyTeleport("Enum.TeleportResult.GameFull"):find("đầy"), "GameFull")
            eq(classifyTeleport("Enum.TeleportResult.Khac"), "Không xác định")
        end)
        add("Guard: chống chạy chồng, nhả khoá đúng token", function()
            local t1 = guardAcquire("test-1")
            truthy(t1, "lấy được khoá")
            local t2, why = guardAcquire("test-2")
            eq(t2, nil, "lần 2 phải bị chặn")
            truthy(why and why:find("test%-1"), "thông báo bận")
            guardRelease(t1 + 99)
            truthy(guard.owner ~= nil, "token sai không nhả")
            guardRelease(t1)
            eq(guard.owner, nil)
            local t3 = guardAcquire("test-3")
            truthy(t3 and t3 ~= t1, "token mới")
            guardRelease(t3)
        end)
        add("Teleport guard: preflight + dry-run không gọi TeleportService", function()
            eq((preflight("", {}, T, 0)), false, "id rỗng")
            eq((preflight(tostring(game.JobId), {}, T, 0)), false, "server hiện tại")
            truthy(preflight("target-0001", {}, T, 0), "hợp lệ")
            eq((preflight("target-0001", { ["target-0001"] = T - 5 }, T, 0)), false, "trùng")
            eq((preflight("target-0002", {}, T, T - 1)), false, "quá dày")
            local before, before2 = teleportGen, lastTeleportAt
            local ok, how = safeTeleport("target-0003", 0, "hop", true)
            eq(ok, true)
            eq(how, "dry-run")
            eq(teleportGen, before, "dry-run không đổi teleportGen")
            eq(lastTeleportAt, before2, "dry-run không ghi lastTeleportAt")
        end)
        return results
    end

    runSelfTest = function()
        local res, why = withGuard("test", function(token)
            local results = selfTestCore()
            guardRelease(token)
            return results
        end)
        if not res then setStatus("Không chạy được Self-Test: " .. tostring(why), THEME.WAIT) return end
        local pass, lines = 0, {}
        for _, r in ipairs(res) do
            if r.ok then pass = pass + 1 end
            lines[#lines + 1] = (r.ok and "✓ " or "✗ ") .. r.name .. (r.err and ("\n   " .. r.err) or "")
        end
        testOut.Size = UDim2.new(1, 0, 1, 0)
        testOut.Parent.Size = UDim2.new(1, 0, 0, math.max(56, 15 * (#res + 1)) + 14)
        testOut.Text = ("Kết quả: %d/%d đạt\n%s"):format(pass, #res, table.concat(lines, "\n"))
        testOut.TextColor3 = (pass == #res) and THEME.OK or THEME.ERR
        setStatus(("Self-Test: %d/%d đạt."):format(pass, #res), (pass == #res) and THEME.OK or THEME.ERR)
        return res
    end

    if GENV.__WX_TEST then
        GENV.__WX_EXPORT = { runSelfTest = runSelfTest, selfTestCore = selfTestCore, validateConfig = validateConfig,
            snapshot = snapshot, settings = function() return settings end, store = store, ui = ui, guard = guard,
            hopOnce = hopOnce, setAuto = setAuto, scanServers = scanServers, net = net, errlog = function() return errlog end,
            quickScan = quickScan, importFromString = importFromString, showTab = showTab, safeTeleport = safeTeleport,
            state = function() return { autoEnabled = autoEnabled, teleportGen = teleportGen, hopRetryCount = hopRetryCount } end }
    end

    -- =================== KHỞI ĐỘNG ===================
    showTab("hop")
    refreshNow()
    ui.onNet()
    updateAutoBtn()
    updateBusyUI()
    syncUI()
    renderLive()
    if resumeAuto then
        setAuto(true, true)
    else
        setStatus("Sẵn sàng. Nhập số người rồi bấm Hop ngay hoặc bật Auto Hop." ..
            (canSave and "" or "\n⚠ Executor không hỗ trợ lưu file — cài đặt chỉ giữ trong phiên."), THEME.TEXT_SUB)
    end
end

local okMain, errMain = pcall(MAIN)
if not okMain then
    GENV.__WX_HUB_RUNNING = nil
    local message = "[wx] Lỗi khởi chạy: " .. tostring(errMain)
    warn(message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "wx", Text = tostring(errMain):sub(1, 180), Duration = 8,
        })
    end)
end
