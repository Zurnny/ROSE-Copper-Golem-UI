-- Presentation only. Native code supplies catalog snapshots and validates every action.
local function el(id) return document:GetElementById(id) end
local function escape(value)
    return (tostring(value or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
        :gsub('"', '&quot;'):gsub("'", '&#39;'))
end
local function amount(value)
    local text = string.format('%.0f', value)
    local result = text:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return result
end
local function disabled(value) return value and ' disabled="disabled"' or '' end
local MONTHLY, SEASONAL, NON_SEASONAL = 5, 2, 4
local state = {category = MONTHLY, subcategory = -1, sort = 'featured', layout = 'grid',
    query = '', points = 0, ready = false, loading = false, selected = nil, premium = false}
local categories, catalog, by_id, visible = {}, {}, {}, {}
local promoted_order = 0
local scrolls, pending_scroll = {}, nil
local scroll_to_listing
local tile_width, tile_height, tile_gap = 92, 100, 6
local rendered_key = '5:-1'
local featured_label, buy_label = 'Monthly', 'Buy'
local scale, last_width, narrow, last_time, toast_until = 1, 0, false, 0, 0
local function grid_columns(width) return math.max(1, math.floor((width / scale + tile_gap) / (tile_width + tile_gap))) end
-- Steampunk theme: measure the item area minus a fixed scrollbar gutter, instead of
-- the list's own width (which shrinks when the scrollbar appears and shifted the cards).
local SCROLLBAR_GUTTER = 18
local function grid_width()
    return math.max(0, el('mall-items-area').client_width - SCROLLBAR_GUTTER * scale)
end
local toast = ''
local render, render_detail, navigate

-- ---------------------------------------------------------------------
-- Wishlist (steampunk add-on). Items are remembered by item key, so a
-- wish survives catalog refreshes. Saved to a small file when the game's
-- Lua allows it; otherwise it lasts until the game is closed.
-- ---------------------------------------------------------------------
local WISHLIST = -100
local WISH_FILE = 'sp_mall_wishlist.txt'
local wishes, wish_order = {}, {}
local function wish_key(item) return tostring(item.item_key or item.listing) end
local function is_wished(item) return item ~= nil and wishes[wish_key(item)] == true end
local function save_wishes()
    pcall(function()
        local f = io.open(WISH_FILE, 'w')
        if not f then return end
        for _, key in ipairs(wish_order) do if wishes[key] then f:write(key, '\n') end end
        f:close()
    end)
end
pcall(function()
    local f = io.open(WISH_FILE, 'r')
    if not f then return end
    for line in f:lines() do
        local key = line:match('^%s*(.-)%s*$')
        if key ~= '' and not wishes[key] then wishes[key] = true; wish_order[#wish_order + 1] = key end
    end
    f:close()
end)
local function set_wish(item, on)
    local key = wish_key(item)
    if on and not wishes[key] then wish_order[#wish_order + 1] = key end
    wishes[key] = on or nil
    if not on then
        for i, k in ipairs(wish_order) do if k == key then table.remove(wish_order, i) break end end
    end
    save_wishes()
end
local function wish_rank(item)
    local key = wish_key(item)
    for i, k in ipairs(wish_order) do if k == key then return i end end
    return math.huge
end
local function wish_pin(item)
    local on = is_wished(item)
    return '<button class="mall-wish-pin' .. (on and ' on' or '') .. '" data-wish="' .. item.listing ..
        '" mall-tooltip="' .. (on and 'Remove from wishlist' or 'Add to wishlist') .. '"/>'
end
local premium_open = false
local function show_premium(open)
    premium_open = open
    document:SetClass('premium-open', open)
    el(open and 'mall-premium-back' or 'mall-premium-link'):Focus()
end
local function render_premium()
    el('mall-premium-title').inner_rml = state.premium and 'Premium active' or 'ROSE Premium'
    el('mall-premium-copy').inner_rml = state.premium and 'Your account has Premium benefits.' or 'More character slots. Extra storage. Storage access anywhere.'
    el('mall-premium-link').inner_rml = state.premium and 'View membership' or 'View benefits'
    el('mall-premium-shop').inner_rml = state.premium and 'Manage subscription in shop' or 'View plans in shop'
    el('mall-premium-banner'):SetClass('visible', not state.premium and state.category == MONTHLY and state.query:match('^%s*$') ~= nil)
end
document:AddEventListener('mall-premium', function(event)
    state.premium = event.parameters.active == true
    render_premium()
end)

local function category_info(id)
    for _, category in ipairs(categories) do if category.id == id then return category end end
end
local function sub_name(item)
    local category = category_info(item.category)
    if category then
        for _, sub in ipairs(category.subs) do if sub.id == item.subcategory then return sub.name end end
    end
    return ''
end
local function path(item)
    local category = category_info(item.category)
    return (category and category.name or featured_label) .. ' / ' .. sub_name(item)
end
local function view_key() return state.query ~= '' and 'search' or tostring(state.category) .. ':' .. state.subcategory end
local function remember_scroll()
    if state.ready and not state.loading and #visible > 0 then scrolls[rendered_key] = el('mall-items').scroll_top end
end
local function notify_view()
    local category, subcategory = state.category, state.subcategory
    if category == WISHLIST then
        local item = by_id[state.selected]
        category, subcategory = item and item.category or MONTHLY, item and item.subcategory or -1
    end
    document:DispatchEvent('mall-view', {category = category, subcategory = subcategory})
end
local function action(kind, listing)
    local item = by_id[listing]
    if not item or not state.ready or state.loading then return end
    if kind == 'buy' and item.price > state.points then return end
    document:DispatchEvent('mall-action', {action = kind, listing = listing})
end
local function item_name(item)
    return escape(item.name) .. ((item.quantity or 1) > 1 and ' (x' .. item.quantity .. ')' or '')
end
local function item_icon(item, prefix)
    -- Legacy overlay values are the atlas cell indices (1..9).
    local overlay = tonumber(item.overlay) or 0
    local badge = overlay >= 1 and overlay <= 9 and overlay == math.floor(overlay) and
        '<img class="mall-overlay" sprite="world-emote-' .. overlay .. '" />' or ''
    -- Quantity already appears in the name; reserve the icon corner for its badge.
    return '<item-slot hide-quantity="" id="' .. prefix .. item.listing .. '">' .. badge .. '</item-slot>'
end
local function currency(price)
    return '<span class="mall-price"><img sprite="mall-points" /><span>' .. amount(price) .. '</span></span>'
end
local function select_item(listing)
    if not by_id[listing] then return end
    local previous = state.selected and el('mall-card-' .. state.selected)
    if previous then previous:SetClass('selected', false) end
    state.selected = listing
    local card = el('mall-card-' .. listing)
    if card then card:SetClass('selected', true) end
    toast = ''
    render_detail()
    notify_view()
end
render_detail = function()
    local item = by_id[state.selected]
    if not item then
        el('mall-detail').inner_rml = '<div class="mall-placeholder"/><div class="ui-status">Select an item to preview it on your character and buy.</div>'
        return
    end
    local unavailable = state.loading or not state.ready
    local after = item.price > state.points and 'Not enough points for this item.' or amount(state.points - item.price) .. ' points left after purchase'
    local pieces, seen = {}, {[item.item_key or item.listing] = true}
    if (item.set_id or 0) > 0 then
        for _, other in ipairs(catalog) do
            local key = other.item_key or other.listing
            if other.set_id == item.set_id and not seen[key] then
                seen[key] = true
                pieces[#pieces + 1] = '<button class="mall-set-piece" data-related="' .. other.listing ..
                    '" mall-item-tooltip="' .. other.listing .. '">' .. escape(other.name) .. '</button>'
            end
        end
    end
    local related = #pieces > 0 and '<div id="mall-set-pieces"><b>Also in this set</b>' .. table.concat(pieces) .. '</div>' or ''
    local comment = (item.comment or ''):match('^%s*(.-)%s*$')
    local comment_markup = comment ~= '' and comment ~= item.description and '<div class="mall-description">' .. escape(comment) .. '</div>' or ''
    el('mall-detail').inner_rml = item_icon(item, 'mall-detail-icon-') ..
        '<div class="mall-detail-name">' .. item_name(item) .. '</div>' ..
        '<div class="mall-detail-path">' .. escape(path(item)) .. '</div>' ..
        '<div id="mall-item-type" class="mall-detail-path">' .. escape(item.item_type) .. '</div>' ..
        '<div id="mall-description" class="mall-description">' .. escape(item.description) .. '</div>' ..
        comment_markup ..
        '<div class="mall-detail-price content-box">' .. currency(item.price) .. '</div>' ..
        '<div class="mall-detail-actions"><button id="mall-detail-buy" class="default" data-action="buy" listing="' .. item.listing .. '"' .. disabled(unavailable or item.price > state.points) .. '>' .. escape(buy_label) .. '</button>' ..
        '<button id="mall-try" class="default" data-action="try" listing="' .. item.listing .. '" mall-tooltip="' .. (item.previewable and 'Preview on your character' or 'This item cannot be tried on') .. '"' .. disabled(unavailable or not item.previewable) .. '>Try on</button></div>' ..
        '<button id="mall-wish" class="default ui-compact' .. (is_wished(item) and ' on' or '') .. '" data-wish="' .. item.listing .. '">' ..
            (is_wished(item) and 'On your wishlist (remove)' or 'Add to wishlist') .. '</button>' ..
        '<div class="mall-after">' .. after .. '</div>' .. related .. '<div id="mall-result">' .. escape(toast) .. '</div>'
end
local function nav_row(id, sub, label, count, active)
    return '<button class="mall-nav-row' .. (sub ~= nil and ' sub' or '') .. (active and ' active' or '') ..
        '" data-category="' .. id .. '" data-subcategory="' .. (sub or -1) .. '"><span>' .. escape(label) ..
        '</span><small>' .. (state.ready and tostring(count) or '') .. '</small></button>'
end
local function render_nav()
    local rows = {}
    local function add_category(id, name, subs)
        local count, counts = 0, {}
        for _, item in ipairs(catalog) do
            if item.category == id then
                count = count + 1
                counts[item.subcategory] = (counts[item.subcategory] or 0) + 1
            end
        end
        rows[#rows + 1] = nav_row(id, nil, string.upper(name), count, state.category == id)
        if state.category == id and #subs > 0 then
            for _, sub in ipairs(subs) do
                rows[#rows + 1] = nav_row(id, sub.id, sub.name, counts[sub.id] or 0, state.subcategory == sub.id)
            end
        end
    end
    table.sort(categories, function(a, b)
        if (a.id == MONTHLY) ~= (b.id == MONTHLY) then return a.id == MONTHLY end
        return a.id < b.id
    end)
    local wished = 0
    for _, item in ipairs(catalog) do if is_wished(item) then wished = wished + 1 end end
    rows[#rows + 1] = nav_row(WISHLIST, nil, 'WISHLIST', wished, state.category == WISHLIST):gsub('class="mall%-nav%-row', 'class="mall-nav-row wishlist', 1)
    for _, category in ipairs(categories) do add_category(category.id, category.name, category.subs) end
    el('mall-nav').inner_rml = table.concat(rows)
end
render = function(reset_scroll)
    local query = state.query:match('^%s*(.-)%s*$'):lower()
    visible = {}
    for _, item in ipairs(catalog) do
        local match = query ~= '' and (item.name .. ' ' .. sub_name(item)):lower():find(query, 1, true) ~= nil
        if query == '' and state.category == WISHLIST then
            match = is_wished(item)
        elseif query == '' then
            match = item.category == state.category and
                (state.subcategory == -1 or item.subcategory == state.subcategory)
        end
        if match then visible[#visible + 1] = item end
    end
    local wish_view = query == '' and state.category == WISHLIST
    table.sort(visible, function(a, b)
        if wish_view and state.sort == 'featured' then return wish_rank(a) < wish_rank(b) end
        if state.sort == 'name' and a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        if state.sort == 'featured' and a.category == MONTHLY and b.category == MONTHLY and a.subcategory ~= b.subcategory then
            return a.subcategory == SEASONAL
        end
        if state.sort == 'featured' and a.featured ~= b.featured then return a.featured end
        if state.sort == 'featured' and a.featured and b.featured and a.promoted_order ~= b.promoted_order then
            return a.promoted_order < b.promoted_order
        end
        return a.order < b.order
    end)
    local selected_visible = false
    local rows = {}
    for _, item in ipairs(visible) do
        selected_visible = selected_visible or state.selected == item.listing
        rows[#rows + 1] = '<div id="mall-card-' .. item.listing .. '" class="mall-card' .. (state.selected == item.listing and ' selected' or '') .. (is_wished(item) and ' wished' or '') .. '" listing="' .. item.listing .. '" tabindex="0">' ..
            item_icon(item, 'mall-icon-') .. wish_pin(item) .. '<div class="mall-name">' .. item_name(item) .. '</div>' .. currency(item.price) ..
            '<button class="mall-buy default ui-compact" data-action="buy" listing="' .. item.listing .. '"' .. disabled(item.price > state.points) .. '>' .. escape(buy_label) .. '</button></div>'
    end
    if not selected_visible then state.selected = nil end
    if #rows == 0 and state.ready and not state.loading then
        rows[1] = wish_view and '<div class="mall-empty">Your wishlist is empty. Click the round pin on any item, or "Add to wishlist" in the item panel.</div>'
            or '<div class="mall-empty">No items match these filters.</div>'
    end
    local items = el('mall-items')
    local old_scroll = items.scroll_top
    items.inner_rml = '<div id="mall-grid-content">' .. table.concat(rows) .. '</div>'
    items:SetClass('list', state.layout == 'list' or narrow)
    last_width = 0
    pending_scroll = {value = reset_scroll and (scrolls[view_key()] or 0) or old_scroll, frames = 2}
    rendered_key = view_key()
    local category = category_info(state.category)
    local heading = state.category == WISHLIST and 'Wishlist' or (category and category.name or featured_label)
    if category and state.subcategory ~= -1 then
        for _, sub in ipairs(category.subs) do if sub.id == state.subcategory then heading = heading .. ' · ' .. sub.name end end
    end
    el('mall-path').inner_rml = escape(query ~= '' and 'Search results' or heading)
    local count_text = #visible .. (#visible == 1 and ' item' or ' items')
    if wish_view and #visible > 0 then
        local total = 0
        for _, item in ipairs(visible) do total = total + (item.price or 0) end
        count_text = count_text .. ' · ' .. amount(total) .. ' points total' ..
            (total <= state.points and ' · you can afford all of it' or ' · ' .. amount(total - state.points) .. ' more points needed')
    end
    el('mall-count').inner_rml = count_text
    el('mall-total').inner_rml = #catalog .. ' in catalog'
    el('mall-points').inner_rml = amount(state.points)
    el('mall-state').inner_rml = state.loading and 'Loading Item Mall...' or (not state.ready and 'Unable to load the catalog. Please refresh.' or '')
    for _, sort in ipairs({'featured', 'name'}) do el('mall-sort-' .. sort):SetClass('active', state.sort == sort) end
    el('mall-grid'):SetClass('active', state.layout == 'grid' and not narrow)
    el('mall-list'):SetClass('active', state.layout == 'list' or narrow)
    if state.loading then el('mall-refresh'):SetAttribute('disabled', 'disabled') else el('mall-refresh'):RemoveAttribute('disabled') end
    render_nav()
    render_premium()
    render_detail()
    notify_view()
end
local function default_subcategory(category, subcategory)
    local info = category_info(category)
    if category ~= MONTHLY and subcategory == -1 and info and #info.subs > 0 then
        return info.subs[1].id
    end
    return subcategory
end
navigate = function(category, subcategory)
    remember_scroll()
    if category == -1 then category = MONTHLY end
    state.category, state.subcategory, state.query = category, default_subcategory(category, subcategory), ''
    el('mall-search'):SetAttribute('value', '')
    render(true)
end

document:AddEventListener('mall-reset', function()
    remember_scroll()
    categories, catalog, by_id = {}, {}, {}
    promoted_order = 0
end)
document:AddEventListener('mall-category', function(event)
    local p = event.parameters
    categories[#categories + 1] = {id = p.id, name = p.name, subs = {}}
end)
document:AddEventListener('mall-subcategory', function(event)
    local p = event.parameters
    if p.category == MONTHLY and p.id ~= SEASONAL and p.id ~= NON_SEASONAL then return end
    local category = category_info(p.category)
    if category then category.subs[#category.subs + 1] = {id = p.id, name = p.name} end
end)
document:AddEventListener('mall-item', function(event)
    local p = event.parameters
    -- Native code sends promoted entries in ascending promoted-slot order.
    -- Keep that order separately from the category order used by the catalog.
    if p.featured then promoted_order = promoted_order + 1 end
    -- Featured entries also occur in the catalog. Keep one card per listing.
    if by_id[p.listing] then
        by_id[p.listing].featured = by_id[p.listing].featured or p.featured
        if p.featured and not by_id[p.listing].promoted_order then
            by_id[p.listing].promoted_order = promoted_order
        end
        return
    end
    -- Promotions change ordering only; they never create a second destination.
    if p.featured then return end
    if p.category == MONTHLY and p.subcategory ~= SEASONAL and p.subcategory ~= NON_SEASONAL then return end
    local item = {}
    for _, key in ipairs({'listing','category','subcategory','name','price','quantity','comment','description','item_type','set_id','item_key','overlay','featured','previewable'}) do item[key] = p[key] end
    item.order = #catalog + 1
    item.promoted_order = p.featured and promoted_order or nil
    catalog[#catalog + 1], by_id[item.listing] = item, item
end)
document:AddEventListener('mall-ready', function(event)
    local p = event.parameters
    state.loading, state.ready, state.points = p.loading, p.ready, p.points
    buy_label = p.buy_label
    el('mall-buy-points').inner_rml = escape(p.buy_points_label)
    if state.ready and not state.loading then
        -- Keep native category IDs and labels intact. Visibility is a UI policy.
        local populated = {}
        for _, item in ipairs(catalog) do
            populated[item.category] = populated[item.category] or {}
            populated[item.category][item.subcategory] = true
        end
        local visible_categories = {}
        for _, category in ipairs(categories) do
            local visible_subs = {}
            for _, sub in ipairs(category.subs) do
                if category.id == MONTHLY or (populated[category.id] and populated[category.id][sub.id]) then
                    visible_subs[#visible_subs + 1] = sub
                end
            end
            category.subs = visible_subs
            if category.id == MONTHLY or #visible_subs > 0 then
                visible_categories[#visible_categories + 1] = category
            end
        end
        categories = visible_categories
        local category = category_info(state.category)
        if not category and state.category ~= WISHLIST then state.category, state.subcategory = MONTHLY, -1 end
        if category and state.subcategory ~= -1 then
            local exists = false
            for _, sub in ipairs(category.subs) do exists = exists or sub.id == state.subcategory end
            if not exists then state.subcategory = -1 end
        end
        state.subcategory = default_subcategory(state.category, state.subcategory)
    end
    render(true)
end)
document:AddEventListener('mall-navigate', function(event) navigate(event.parameters.category, event.parameters.subcategory) end)
document:AddEventListener('mall-points', function(event)
    state.points = event.parameters.points
    render(false)
end)
document:AddEventListener('mall-result', function(event)
    toast, toast_until = event.parameters.message, last_time + 6
    render_detail()
    notify_view()
end)
document:AddEventListener('hide', function()
    premium_open = false
    document:SetClass('premium-open', false)
    remember_scroll()
    state.query, state.selected, toast = '', nil, ''
    el('mall-search'):SetAttribute('value', '')
end)
document:AddEventListener('keydown', function(event)
    if premium_open then return end
    if event.parameters.key_identifier ~= 70 then return end
    local groups = {'mall-nav', 'mall-premium-card', 'mall-toolbar', 'mall-premium-banner', 'mall-items', 'mall-detail', 'mall-footer'}
    local current, target = 0, event.target_element
    while target do
        for index, id in ipairs(groups) do if target.id == id then current = index end end
        target = target.parent_node
    end
    local step = event.parameters.shift_key == 1 and -1 or 1
    for offset = 1, #groups do
        local index = (current - 1 + step * offset) % #groups + 1
        local id = groups[index]
        if (id ~= 'mall-detail' or not narrow) and
            (id ~= 'mall-premium-banner' or el(id):IsClassSet('visible')) then
            local focus = el(id):QuerySelector('input, button:not([disabled]), .mall-card')
            if focus then focus:Focus(); event:StopPropagation(); return end
        end
    end
end)
el('mall-search'):AddEventListener('change', function(event)
    remember_scroll()
    state.query = event.parameters.value or ''
    scrolls.search = 0
    render(true)
end)
el('mall-more'):AddEventListener('click', function()
    local items = el('mall-items')
    items.scroll_top = items.scroll_top + math.max(1, items.client_height * 0.75)
end)
document:AddEventListener('click', function(event)
    local target = event.target_element
    while target and target ~= document do
        local premium = target:GetAttribute('data-premium')
        if premium then show_premium(premium == 'open'); event:StopPropagation(); return end
        local wish = tonumber(target:GetAttribute('data-wish'))
        if wish and by_id[wish] then
            event:StopPropagation()
            set_wish(by_id[wish], not is_wished(by_id[wish]))
            render(false)
            return
        end
        local related = tonumber(target:GetAttribute('data-related'))
        if related and by_id[related] then
            local item = by_id[related]
            navigate(item.category, item.subcategory)
            select_item(related)
            scroll_to_listing = related
            event:StopPropagation()
            return
        end
        local kind = target:GetAttribute('data-action')
        if kind then
            event:StopPropagation()
            if not target:HasAttribute('disabled') then action(kind, tonumber(target:GetAttribute('listing'))) end
            return
        end
        local category = target:GetAttribute('data-category')
        if category then navigate(tonumber(category), tonumber(target:GetAttribute('data-subcategory'))); return end
        local sort, layout = target:GetAttribute('data-sort'), target:GetAttribute('data-layout')
        if sort then state.sort = sort; render(false); return end
        if layout then state.layout = layout; render(false); return end
        local listing = target:GetAttribute('listing')
        if listing then select_item(tonumber(listing)); return end
        target = target.parent_node
    end
end)
el('mall-items'):AddEventListener('keydown', function(event)
    local key = event.parameters.key_identifier
    -- Rml::Input key identifiers. Restrict buying/navigation to catalog focus.
    if key == 72 then
        local target = event.target_element
        while target and not target:HasAttribute('listing') do target = target.parent_node end
        action('buy', state.selected or (target and tonumber(target:GetAttribute('listing'))))
        event:StopPropagation()
        return
    end
    if key < 90 or key > 93 then return end
    local columns = 1
    if state.layout == 'grid' and not narrow then columns = grid_columns(grid_width()) end
    local index = 1
    for i, item in ipairs(visible) do if item.listing == state.selected then index = i; break end end
    local step = ({[90]=-1, [91]=-columns, [92]=1, [93]=columns})[key]
    local item = visible[math.max(1, math.min(#visible, index + step))]
    if item then
        select_item(item.listing)
        local card = el('mall-card-' .. item.listing)
        card:Focus(); card:ScrollIntoView(false)
    end
    event:StopPropagation()
end)
document:AddEventListener('mall-tick', function(event)
    scale, last_time = event.parameters.scale, event.parameters.time
    local next_narrow = event.parameters.width < 900
    if narrow ~= next_narrow then
        narrow = next_narrow
        document:SetClass('mall-narrow', narrow)
        render(false)
    end
    local items = el('mall-items')
    local width = grid_width()
    if width > 0 and width ~= last_width then
        last_width = width
        local list = state.layout == 'list' or narrow
        local columns = list and 1 or grid_columns(width)
        -- Fixed slots, never stretch cards. Distribute spare width between columns
        -- so the last column stays next to the scrollbar/detail panel.
        local stride = columns > 1 and (width / scale - tile_width) / (columns - 1) or tile_width + tile_gap
        for index, item in ipairs(visible) do
            local card = el('mall-card-' .. item.listing)
            card.style.width = list and '100%' or tile_width .. 'dp'
            card.style.left = ((index - 1) % columns) * stride .. 'dp'
            card.style.top = math.floor((index - 1) / columns) * (list and 63 or tile_height + tile_gap) .. 'dp'
        end
        el('mall-grid-content').style.height = (#visible == 0 and 80 or
            math.ceil(#visible / columns) * (list and 63 or tile_height + tile_gap) - tile_gap) .. 'dp'
        if pending_scroll then pending_scroll.frames = 2 end
    end
    if scroll_to_listing and not pending_scroll then
        local card = el('mall-card-' .. scroll_to_listing)
        if card then card:Focus(); card:ScrollIntoView(false) end
        scroll_to_listing = nil
    end
    if pending_scroll then
        pending_scroll.frames = pending_scroll.frames - 1
        if pending_scroll.frames == 0 then items.scroll_top = pending_scroll.value; pending_scroll = nil end
    end
    el('mall-more'):SetClass('visible', state.ready and not state.loading and
        items.scroll_height > items.client_height + 1 and
        items.scroll_top + items.client_height < items.scroll_height - 1)
    local purchases = el('mall-purchases-side')
    purchases:SetClass('active', event.parameters.purchases_open == true)
    purchases:SetAttribute('aria-expanded', event.parameters.purchases_open and 'true' or 'false')
    if toast ~= '' and last_time >= toast_until then
        toast = ''
        local result = el('mall-result')
        if result then result.inner_rml = '' end
    end
end)
