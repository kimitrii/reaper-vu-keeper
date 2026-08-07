-- @description Action Toolbar (Icon Browser)
-- @version 1.0
-- @author Kimitri

local script_name = "Action Toolbar (Icon Browser)"
local section = "ActionToolbarIconBrowserDockState"

------------------------------------------------------------
-- Detect and toggle instance
------------------------------------------------------------
if reaper.JS_Window_Find then
    local hwnd = reaper.JS_Window_Find(script_name, true)
    if hwnd then
        reaper.JS_Window_Destroy(hwnd)
        return
    end
end

--  Retrieve previous docking state
local dock_state = tonumber(reaper.GetExtState(section, "dock_state")) or 0
gfx.init(script_name, 600, 500, dock_state)

reaper.defer(function()
    local hwnd = reaper.JS_Window_Find(script_name, true)
    if hwnd then
        reaper.JS_Window_SetFocus(hwnd)
    end
end)


------------------------------------------------------------
-- Colors and fonts
------------------------------------------------------------
local theme_color = reaper.GetThemeColor("col_main_bg2", 0)
if theme_color == -1 then theme_color = reaper.GetThemeColor("col_main_bg", 0) end

local function colorToRGB(color)
    local r = color & 0xFF
    local g = (color >> 8) & 0xFF
    local b = (color >> 16) & 0xFF
    return r/255, g/255, b/255
end

local bg_r, bg_g, bg_b = colorToRGB(theme_color)
local bg_color_native = reaper.ColorToNative(bg_r * 255, bg_g * 255, bg_b * 255) 

gfx.setfont(1, "Arial", 16)
local was_lmb = false
local active_button = nil

------------------------------------------------------------
-- Load buttons from .ini file
------------------------------------------------------------
local config_dir = reaper.GetResourcePath() .. "/scripts/ActionToolbarIconBrowser"
local config_path = config_dir .. "/ActionToolbarIconBrowserConfig.ini"

if not reaper.file_exists(config_dir) then
    reaper.RecursiveCreateDirectory(config_dir, 0)
end

local icon_path = reaper.GetResourcePath() .. "/Data/toolbar_icons/"
local track_templates_path = reaper.GetResourcePath() .. "/TrackTemplates/"

local function parse_ini(path)
    local f = io.open(path, "r")
    if not f then return {}, {} end

    local menu_buttons = {}
    local content_buttons = {}
    local current_section

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$") -- trim
        if line ~= "" and not line:match("^;") then
            local section = line:match("^%[(.-)%]$")
            if section then
                current_section = section
                if section ~= "Menu" then
                    content_buttons[section] = {}
                end
            elseif current_section then
                local key, value = line:match("^(.-)=(.+)$")
                if key and value then
                    key = key:match("^%s*(.-)%s*$")
                    value = value:match("^%s*(.-)%s*$")

                    if current_section == "Menu" then
                        local category, parent = value:match("^(.-):(.+)$")
                        if not category then category = value end
                        table.insert(menu_buttons, { name = key, category = category, parent = parent })
                    else
                        local cmd, img = value:match("([^,]+),%s*(.+)")
                        table.insert(content_buttons[current_section], {
                            name = key,
                            cmd = cmd,
                            image = icon_path .. img
                        })
                    end
                end
            end
        end
    end

    f:close()
    return menu_buttons, content_buttons
end

local menu_buttons, content_buttons = parse_ini(config_path)

local active_category = menu_buttons[1] and menu_buttons[1].category or nil
local active_menu_index = 1
local active_content_index = 0

------------------------------------------------------------
-- save data to /FXCustomBrowserConfig/FXBrowserConfig.ini
------------------------------------------------------------
local function save_to_ini(path, menu_buttons, content_buttons)
    local f = io.open(path, "w")
    if not f then return end

    f:write("[Menu]\n")
    for _, btn in ipairs(menu_buttons) do
        if btn.parent then
            f:write(("%s=%s:%s\n"):format(btn.name, btn.category, btn.parent))
        else
            f:write(("%s=%s\n"):format(btn.name, btn.category))
        end
    end
    f:write("\n")

    for cat, list in pairs(content_buttons) do
        f:write(("[" .. cat .. "]\n"))
        for _, fx in ipairs(list) do
            local img = fx.image:match("([^/\\]+)$") or fx.image 
            f:write(("%s=%s,%s\n"):format(fx.name, fx.cmd, img))
        end
        f:write("\n")
    end
    f:close()
end

------------------------------------------------------------
-- Build the sidebar row list: each expanded category is followed
-- inline by its subcategories. Recurses, so nested subcategories
-- work the same way. The "add subcategory" control is drawn on the
-- right side of the category's own row (see draw_menu), not as a
-- separate row here - only the root "add category" row lives here.
------------------------------------------------------------
local function build_menu_rows()
    local rows = {}
    local function walk(parent_id, depth)
        for _, btn in ipairs(menu_buttons) do
            if btn.parent == parent_id then
                table.insert(rows, { kind = "category", btn = btn, depth = depth })
                if btn.expanded then
                    walk(btn.category, depth + 1)
                end
            end
        end
    end
    walk(nil, 0)
    table.insert(rows, { kind = "add", parent = nil, depth = 0 })
    return rows
end

------------------------------------------------------------
-- load images with cache
------------------------------------------------------------
local next_image_id = 0
local loaded_images = {}

local function load_image(path)
    if not path or path == "" then return nil end
    if loaded_images[path] then return loaded_images[path].id end

    next_image_id = next_image_id + 1
    local id = next_image_id
    local success = gfx.loadimg(id, path)
    if success ~= -1 then
        local w, h = gfx.getimgdim(id)
        loaded_images[path] = { id = id, w = w, h = h }
        return id
    end
    return nil
end

------------------------------------------------------------
-- Track templates (buttons store "TEMPLATE:filename.RTrackTemplate" in cmd)
------------------------------------------------------------
local function list_track_templates()
    local files = {}
    local i = 0
    while true do
        local fn = reaper.EnumerateFiles(track_templates_path, i)
        if not fn then break end
        if fn:match("%.RTrackTemplate$") then table.insert(files, fn) end
        i = i + 1
    end
    return files
end

local function insert_track_template(template_file)
    local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    if tr then reaper.SetOnlyTrackSelected(tr) end
    reaper.Main_openProject(track_templates_path .. template_file)
end

------------------------------------------------------------
-- Run content button actions
------------------------------------------------------------
local function run_action(cmd_id)
    local template_file = cmd_id:match("^TEMPLATE:(.+)$")
    if template_file then
        insert_track_template(template_file)
        return
    end

    local command = reaper.NamedCommandLookup(cmd_id)
    if command and command ~= 0 then
        reaper.Main_OnCommand(command, 0)
    else
        reaper.ShowMessageBox("Command ID inválido: " .. tostring(cmd_id), "Erro", 0)
    end
end

------------------------------------------------------------
-- Draw sidebar menu
------------------------------------------------------------
local menu_scroll_y = 0
local menu_max_scroll = 0
local scroll_y = 0
local max_scroll = 0
local menu_focus_add = false -- true when up/down navigation has reached the trailing "add category" row
local menu_focus_subadd = false -- true when right-arrow navigation has reached the active category's inline "add subcategory" button
local content_focus_add = false -- true when left/right navigation has reached the trailing "add action" button

local function active_category_expanded()
    for _, b in ipairs(menu_buttons) do
        if b.category == active_category then return b.expanded end
    end
    return false
end

local function collapse_subtree(category)
    for _, b in ipairs(menu_buttons) do
        if b.parent == category then
            b.expanded = false
            collapse_subtree(b.category)
        end
    end
end

-- Selects btn as the active category and expands its subcategories,
-- closing sibling categories at the same level so only one stays open.
-- force_open makes it always end up expanded (used for arrow-key nav);
-- otherwise a click on an already-open category closes it (toggle).
local function select_category(btn, force_open)
    menu_focus_add = false
    menu_focus_subadd = false
    if active_category ~= btn.category then
        active_category = btn.category
        scroll_y = 0
        active_content_index = 0
        content_focus_add = false
    end
    local was_expanded = btn.expanded
    for _, sib in ipairs(menu_buttons) do
        if sib.parent == btn.parent then
            sib.expanded = false
            collapse_subtree(sib.category)
        end
    end
    btn.expanded = force_open or (not was_expanded)
end

local function add_subcategory(parent_category)
    local ok, name = reaper.GetUserInputs("New Subcategory", 1, "Display name:", "")
    if not ok or name == "" then return end

    local category = name:lower():gsub("[^%w]+", "_") .. "_" .. tostring(#menu_buttons + 1)
    table.insert(menu_buttons, { name = name, category = category, parent = parent_category })
    content_buttons[category] = {}
    save_to_ini(config_path, menu_buttons, content_buttons)
end

local function draw_menu(mx, my, lmb)
    local x_base, indent_w, btn_h, spacing = 0, 20, 35, 10
    local plus_w, plus_gap = 30, 8
    local plus_reserve = plus_w + plus_gap -- left column reserved for a category's inline "+"
    local y = 0 - menu_scroll_y
    local visible_limit = gfx.h + 50

    local rows = build_menu_rows()

    for _, row in ipairs(rows) do
        -- x is the row's indent anchor (also the inline "+" position);
        -- the category button itself sits to the right, past the
        -- reserved "+" column, so top-level rows still have room for it.
        local x = x_base + row.depth * indent_w
        local box_x = x + plus_reserve

        if y + btn_h >= 0 and y <= visible_limit then
            if row.kind == "category" then
                local btn = row.btn
                -- While keyboard focus has moved onto the trailing "add" row
                -- or this category's own inline "+", the category itself is
                -- no longer the focused element, so don't paint it as
                -- selected too.
                local active = (btn.category == active_category) and not menu_focus_add and not menu_focus_subadd

                -- Adjust button width according to text
                local text_w, text_h = gfx.measurestr(btn.name)
                local padding = 20
                local min_w = 120
                local btn_w_dynamic = math.max(min_w, text_w + padding)

                local hover = mx > box_x and mx < box_x + btn_w_dynamic and my > y and my < y + btn_h

                -- Colors
                if active then
                    gfx.set(0.2, 0.6, 1.0)
                elseif hover then
                    gfx.set(0.45, 0.45, 0.55)
                else
                    gfx.set(0.35, 0.35, 0.35)
                end

                -- Draw button with adjusted width
                gfx.roundrect(box_x, y, btn_w_dynamic, btn_h, 6, 1)

                -- Vertically centered text
                gfx.x = box_x + 10
                gfx.y = y + (btn_h - text_h) / 2
                gfx.set(1, 1, 1)
                gfx.drawstr(btn.name)

                -- "add subcategory" control, to the left of the category
                -- button. Only drawn for the active category itself - an
                -- expanded ancestor on the path down to it doesn't show
                -- its own, since it isn't the current selection. Also
                -- hidden once keyboard focus has moved past the category
                -- list onto the trailing "add category" row.
                if btn.expanded and btn.category == active_category and not menu_focus_add then
                    local plus_x = x
                    local plus_hover = mx > plus_x and mx < plus_x + plus_w and my > y and my < y + btn_h
                    if menu_focus_subadd then
                        gfx.set(0.2, 0.6, 1.0)
                    else
                        gfx.set(plus_hover and 0.4 or 0.3, plus_hover and 0.5 or 0.3, plus_hover and 0.6 or 0.3)
                    end
                    gfx.roundrect(plus_x, y, plus_w, btn_h, 6, 1)
                    gfx.x, gfx.y = plus_x + 10, y + 8
                    gfx.set(1, 1, 1)
                    gfx.drawstr("+")

                    if plus_hover and lmb and not was_lmb then
                        add_subcategory(btn.category)
                    end
                end

                -- Click: select category (shows its content) and toggle its subcategories
                if hover and lmb and not was_lmb then
                    select_category(btn)
                end
            else
                -- root "add category" row (the only remaining row of this kind).
                -- Aligned with the category buttons' own column (box_x), not
                -- the reserved inline-"+" column, since it isn't scoped to
                -- any particular category.
                local hover = mx > box_x and mx < box_x + 50 and my > y and my < y + btn_h
                if menu_focus_add then
                    gfx.set(0.2, 0.6, 1.0)
                else
                    gfx.set(hover and 0.4 or 0.3, hover and 0.5 or 0.3, hover and 0.6 or 0.3)
                end
                gfx.roundrect(box_x, y, 50, btn_h, 6, 1)
                gfx.x, gfx.y = box_x + 20, y + 8
                gfx.set(1, 1, 1)
                gfx.drawstr("+")

                if hover and lmb and not was_lmb then
                    add_subcategory(row.parent)
                end
            end
        end
        y = y + btn_h + spacing
    end

    -- Keep active_menu_index in sync with the currently selected category
    -- (indexes the category-only list, matching the arrow-key handlers).
    -- Skipped while focus sits on the trailing "add" row, since that row
    -- isn't a category and would have nothing to sync against.
    if not menu_focus_add then
        local cat_i = 0
        for _, row in ipairs(rows) do
            if row.kind == "category" then
                cat_i = cat_i + 1
                if row.btn.category == active_category then
                    active_menu_index = cat_i
                    break
                end
            end
        end
    end

    menu_max_scroll = math.max(0, (#rows * (btn_h + spacing)) - gfx.h + 90)
end

------------------------------------------------------------
-- Add a new action/track-template button to the active category.
-- Shared by the content pane's mouse click and its keyboard Enter.
------------------------------------------------------------
local function add_content_button()
    if not active_category then
        reaper.ShowMessageBox("No active category.", "Warning", 0)
        return
    end

    local choice = gfx.showmenu("Action ID|Track Template")

    if choice == 1 then
        local ok, ret = reaper.GetUserInputs("New Action Button", 3, "Name:,Action ID:,Image file (ex: MyIcon.png):", "")
        if ok then
            local name, cmd, img = ret:match("([^,]+),([^,]+),([^,]+)")
            if name and cmd and img then
                table.insert(content_buttons[active_category], { name=name, cmd=cmd, image=icon_path .. img })
                save_to_ini(config_path, menu_buttons, content_buttons)
            end
        end

    elseif choice == 2 then
        local templates = list_track_templates()
        if #templates == 0 then
            reaper.ShowMessageBox("No .RTrackTemplate files found in " .. track_templates_path, "Warning", 0)
        else
            local t_choice = gfx.showmenu(table.concat(templates, "|"))
            if t_choice > 0 then
                local template_file = templates[t_choice]
                local ok, ret = reaper.GetUserInputs("New Track Template Button", 2, "Name:,Image file (ex: MyIcon.png):", "")
                if ok then
                    local name, img = ret:match("([^,]+),([^,]+)")
                    if name and img then
                        table.insert(content_buttons[active_category], { name=name, cmd="TEMPLATE:" .. template_file, image=icon_path .. img })
                        save_to_ini(config_path, menu_buttons, content_buttons)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Draw content with scroll (optimized)
------------------------------------------------------------

local function draw_content(mx, my, lmb)
    local x_start = 180
    local y_start = 0 - scroll_y
    local spacing_x, spacing_y = 20, 20
    local list = content_buttons[active_category] or {}

    local x = x_start
    local y = y_start
    local line_height = 0
    local available_width = gfx.w - x_start - 20
    local visible_limit = gfx.h + 150

    ------------------------------------------------------------
    -- Pre-calculate total height (without drawing)
    ------------------------------------------------------------
    local total_height = 0
    local temp_x, temp_line_height = 0, 0

    for _, btn in ipairs(list) do
        local img_data = loaded_images[btn.image]
        if not img_data then load_image(btn.image) img_data = loaded_images[btn.image] end
        if img_data then
            local iw, ih = img_data.w / 3, img_data.h
            if temp_x + iw > available_width then
                total_height = total_height + temp_line_height + spacing_y
                temp_x, temp_line_height = 0, 0
            end
            temp_x = temp_x + iw + spacing_x
            temp_line_height = math.max(temp_line_height, ih)
        end
    end
    total_height = total_height + temp_line_height + spacing_y + 30  

    ------------------------------------------------------------
    --  Draw content
    ------------------------------------------------------------
    for i, btn in ipairs(list) do
        local img_data = loaded_images[btn.image]
        if img_data then
            local img_id, iw, ih = img_data.id, img_data.w / 3, img_data.h
            local frame_w, frame_h = iw, ih

            if x + frame_w > gfx.w - 20 then
                x = x_start
                y = y + line_height + spacing_y
                line_height = 0
            end

            line_height = math.max(line_height, frame_h)

            if y + frame_h >= 0 and y <= visible_limit then
                local offset_y = (line_height - frame_h) / 2
                local hover = mx > x and mx < x + frame_w and my > y + offset_y and my < y + offset_y + frame_h

                if hover then
                    hovered_icon_name = btn.name
                end

                -- Keyboard selected icon
                local selected = (i == active_content_index) 

                local active = (active_button == btn)
                local src_x = active and frame_w * 2 or (hover and frame_w or 0)

                gfx.blit(img_id, 1, 0, src_x, 0, frame_w, frame_h, x, y + offset_y, frame_w, frame_h)

                if selected then
                    gfx.set(0.2, 0.6, 1.0, 1) 
                    gfx.rect(x - 2, y + offset_y - 2, frame_w + 4, frame_h + 4, false)
                end

                if hover and lmb and not was_lmb then
                    active_button = btn
                    active_content_index = i
                    run_action(btn.cmd)
                    gfx.quit()
                end
            end

            x = x + frame_w + spacing_x
        end
    end

    y = y + line_height + spacing_y

    ------------------------------------------------------------
    -- Add button (fixed after everything)
    ------------------------------------------------------------
    local hover = mx > x_start and mx < x_start + 50 and my > y and my < y + 30
    if content_focus_add then
        gfx.set(0.2, 0.6, 1.0)
    else
        gfx.set(hover and 0.4 or 0.3, hover and 0.5 or 0.3, hover and 0.6 or 0.3)
    end
    gfx.roundrect(x_start, y, 50, 30, 6, 1)
    gfx.x, gfx.y = x_start + 20, y + 8
    gfx.set(1, 1, 1)
    gfx.drawstr("+")

    if hover and lmb and not was_lmb then
        add_content_button()
    end

    if hovered_icon_name then
        gfx.set(0, 0, 0, 0.75)
        local text_w, text_h = gfx.measurestr(hovered_icon_name)
        gfx.rect(mx + 12, my + 20, text_w + 10, text_h + 6, true)
        gfx.set(1, 1, 1, 1)
        gfx.x, gfx.y = mx + 17, my + 23
        gfx.drawstr(hovered_icon_name)
    end
    hovered_icon_name = nil


    ------------------------------------------------------------
    -- max scroll based on total height
    ------------------------------------------------------------
    max_scroll = math.max(0, total_height - (gfx.h - 50))
end

------------------------------------------------------------
-- Up/down arrow-key navigation of the sidebar: steps through the
-- category list, ending on the trailing "add category" row, which
-- is treated as if it were simply the last item of that list.
------------------------------------------------------------
local function navigate_menu(delta)
    local rows = build_menu_rows()
    if #rows == 0 then return end

    active_menu_index = math.max(1, math.min(active_menu_index + delta, #rows))
    local entry = rows[active_menu_index]

    if entry.kind == "category" then
        select_category(entry.btn, true)
    else
        menu_focus_add = true
    end

    local btn_h, spacing = 35, 10
    local top_visible = menu_scroll_y
    local bottom_visible = menu_scroll_y + gfx.h - 80
    local btn_y = (active_menu_index - 1) * (btn_h + spacing)
    if btn_y < top_visible then
        menu_scroll_y = btn_y
    elseif btn_y + btn_h > bottom_visible then
        menu_scroll_y = btn_y + btn_h - (gfx.h - 80)
    end
    menu_scroll_y = math.max(0, math.min(menu_scroll_y, menu_max_scroll))
end

------------------------------------------------------------
-- Scrolls the content pane so the item at `index` in `list` is
-- visible. Shared by left/right content navigation and by the
-- sidebar -> content focus transition.
------------------------------------------------------------
local function reveal_content_item(list, index)
    if index <= 0 then return end
    local img_data = loaded_images[list[index].image]
    if not img_data then return end

    local ih = img_data.h
    local spacing_x, spacing_y = 20, 20
    local x_start, y_start = 180, 40

    local x, y = x_start, y_start
    for i = 1, index - 1 do
        local btn_img = loaded_images[list[i].image]
        if btn_img then
            local iw2, ih2 = btn_img.w / 3, btn_img.h
            if x + iw2 > gfx.w - 20 then
                x = x_start
                y = y + ih2 + spacing_y
            end
            x = x + iw2 + spacing_x
        end
    end

    local top_visible = scroll_y
    local bottom_visible = scroll_y + gfx.h - 100
    local item_top = y
    local item_bottom = y + ih

    if item_top < top_visible then
        scroll_y = item_top
    elseif item_bottom > bottom_visible then
        scroll_y = item_bottom - (gfx.h - 100)
    end

    scroll_y = math.max(0, math.min(scroll_y, max_scroll))
end

------------------------------------------------------------
function main()
    gfx.clear = bg_color_native
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local lmb = gfx.mouse_cap & 1 == 1

    -- Independent scroll for menu and content
    local mw = gfx.mouse_wheel
    if mw ~= 0 then
        if mx < 160 then
            -- Scroll in menu (left side)
            menu_scroll_y = math.max(0, math.min(menu_scroll_y - mw / 120 * 30, menu_max_scroll))
        else
            -- Scroll in content
            scroll_y = math.max(0, math.min(scroll_y - mw / 120 * 30, max_scroll))
        end
    end
    gfx.mouse_wheel = 0


    draw_menu(mx, my, lmb)
    draw_content(mx, my, lmb)

    if was_lmb and not lmb then
        active_button = nil
    end

    was_lmb = lmb
    gfx.update()

    local char = gfx.getchar()

-- If ESC is pressed, exit the script (or step focus back first)
    if char == 27 then
        if content_focus_add then
            content_focus_add = false
        elseif menu_focus_subadd then
            menu_focus_subadd = false
        elseif active_content_index ~= 0 then
            active_content_index = 0
        elseif menu_focus_add then
            menu_focus_add = false
        else
            gfx.quit()
            return
        end
    end

    ------------------------------------------------------------
    -- ↑ up arrow = previous menu
    ------------------------------------------------------------
    if char == 30064 then
        navigate_menu(-1)
    end

    ------------------------------------------------------------
    -- ↓ down arrow = next menu
    ------------------------------------------------------------
    if char == 1685026670 then
        navigate_menu(1)
    end

    ------------------------------------------------------------
    -- ← Left arrow = the "+" sits to the left of the category now, so
    -- Left reaches it: from nothing selected, if the active category
    -- is expanded, Left focuses its inline "+" (add subcategory);
    -- from there, nothing further left. Otherwise Left steps backward
    -- through content items (and back from the trailing "add action").
    -- Disabled while focus is on the root "add category" row, since
    -- that row isn't a category and has no content/subadd of its own.
    ------------------------------------------------------------
    if char == 1818584692 and not menu_focus_add then
        local list = content_buttons[active_category] or {}
        if content_focus_add then
            content_focus_add = false
            active_content_index = #list
            reveal_content_item(list, active_content_index)
        elseif active_content_index > 0 then
            active_content_index = active_content_index - 1
            reveal_content_item(list, active_content_index)
        elseif not menu_focus_subadd and active_category_expanded() then
            menu_focus_subadd = true
        end
    end

    ------------------------------------------------------------
    -- → Right arrow = steps out of the inline "+" back to the category,
    -- then forward through content items; past the last one, lands on
    -- the trailing "add action" button. Disabled while focus is on the
    -- root "add category" row, for the same reason as Left above.
    ------------------------------------------------------------
    if char == 1919379572 and not menu_focus_add then
        local list = content_buttons[active_category] or {}
        if menu_focus_subadd then
            menu_focus_subadd = false
        elseif content_focus_add then
            -- already on the trailing "add" button, nothing further right
        elseif active_content_index >= #list then
            content_focus_add = true
            active_content_index = 0
        else
            active_content_index = active_content_index + 1
            reveal_content_item(list, active_content_index)
        end
    end

    ------------------------------------------------------------
    -- Enter = executar ação do item ativo
    ------------------------------------------------------------
    if char == 13 then
        if menu_focus_add then
            add_subcategory(nil)
        elseif menu_focus_subadd then
            add_subcategory(active_category)
        elseif content_focus_add then
            add_content_button()
        else
            local list = content_buttons[active_category] or {}
            local btn = list[active_content_index]
            if btn then
                run_action(btn.cmd)
            end
        end
    end

    if char >= 0 then
        reaper.defer(main)
    else
        gfx.quit()
    end

end

reaper.atexit(function()
    reaper.SetExtState(section, "dock_state", tostring(gfx.dock(-1)), true)
end)

main()
