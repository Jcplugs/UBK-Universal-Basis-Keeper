-- Shared UBK tables: one measured grid for headers and cells, never space-padded text.
-- Render(ctx, opts) accepts rows, columns, state {key,ascending,page,offset}, and
-- onChange/onClick/onRightClick/onEnter callbacks. Column value controls sorting;
-- column text controls display. Missing values always sort after known values.
_G.UBKTableUI = {}
local T = _G.UBKTableUI

local function Available(v)
    return v ~= nil and v ~= false and (type(v) ~= "number" or (v == v and v > -math.huge and v < math.huge))
end
T.Available = Available

function T.SortRows(rows, columns, state)
    local out = {}; for i, row in ipairs(rows or {}) do out[i] = row end
    local column
    for _, c in ipairs(columns or {}) do if c.key == state.key then column = c; break end end
    local function Value(row)
        local v
        if column and column.value then v=column.value(row) else v=row[state.key] end
        if type(v) == "string" then return v:lower() end
        return v
    end
    table.sort(out, function(a,b)
        local av,bv=Value(a),Value(b)
        local ah,bh=Available(av),Available(bv)
        if ah ~= bh then return ah end
        if ah and av ~= bv then
            if type(av) ~= type(bv) then av,bv=tostring(av),tostring(bv) end
            if state.ascending then return av < bv else return av > bv end
        end
        local an,bn=tostring(a.name or a.itemString or ""):lower(),tostring(b.name or b.itemString or ""):lower()
        if an ~= bn then return an < bn end
        return tostring(a.itemString or "") < tostring(b.itemString or "")
    end)
    return out
end

function T.FilterRows(rows, filters, goldField)
    local out={}
    for _,r in ipairs(rows or {}) do
        local include=T.NameMatches(r.name or r.itemString,filters.search)
        if include and filters.profession and filters.profession~="ALL" then
            include=r.professions and r.professions[filters.profession] == true or false
        end
        if include and filters.itemType and filters.itemType~="ALL" then include=r.itemType==filters.itemType end
        if include and filters.quality and filters.quality~="ALL" then include=tostring(r.quality)==tostring(filters.quality) end
        local gold=filters.gold or "ALL"
        local value=r[goldField or "goldValue"]
        if include and gold~="ALL" then
            if gold=="UNKNOWN" then include=not Available(value)
            elseif not Available(value) then include=false
            elseif gold=="UNDER1" then include=value<10000
            elseif gold=="1TO10" then include=value>=10000 and value<100000
            elseif gold=="10TO20" then include=value>=100000 and value<200000
            elseif gold=="20TO50" then include=value>=200000 and value<500000
            elseif gold=="50PLUS" then include=value>=500000 end
        end
        if include then out[#out+1]=r end
    end
    return out
end

function T.ColumnGeometry(columns, width, minWidth)
    local natural=0
    for _,c in ipairs(columns) do natural=natural+(c.width or 90) end
    local full=math.max(width or natural,minWidth or natural)
    local scale=full/natural
    local x,layout=0,{}
    for i,c in ipairs(columns) do
        local nextX=i==#columns and full or x+(c.width or 90)*scale
        layout[i]={x=x,width=nextX-x}; x=nextX
    end
    return layout,full
end

local function Text(ctx,parent,template)
    if ctx.MakeText then return ctx.MakeText(parent,template) end
    return parent:CreateFontString(nil,"OVERLAY",template or "GameFontHighlightSmall")
end
local function Button(ctx,parent,label,w,h)
    if ctx.MakeButton then return ctx.MakeButton(parent,label,w,h) end
    local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate"); b:SetSize(w,h); b:SetText(label); return b
end
local function Solid(parent,x,y,w,h,r,g,b,a)
    local t=parent:CreateTexture(nil,"ARTWORK"); t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetPoint("TOPLEFT",x,y); t:SetSize(w,h); t:SetVertexColor(r or .43,g or .34,b or .19,a or 1); return t
end
T.Solid=Solid
local function Tooltip(owner,title,body)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner,"ANCHOR_RIGHT"); GameTooltip:AddLine(title,1,.82,.3)
    if body then GameTooltip:AddLine(body,.88,.88,.88,true) end
    GameTooltip:Show()
end

-- A small scrollable picker avoids the version-sensitive Blizzard menu APIs.
function T.Picker(ctx,parent,x,y,width,label,value,options,onSelect,help)
    local b=Button(ctx,parent,"",width,25); b:SetPoint("TOPLEFT",x,y)
    local selected="All"
    for _,o in ipairs(options) do if tostring(o.value)==tostring(value) then selected=o.label; break end end
    b:SetText(label..": "..selected.." v")
    b:SetScript("OnEnter",function(self) Tooltip(self,label,help or "Choose a filter. The source data is unchanged.") end)
    b:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    b:SetScript("OnClick",function()
        if b.menu and b.menu:IsShown() then b.menu:Hide(); return end
        if ctx.UI and ctx.UI.ubkActivePicker then ctx.UI.ubkActivePicker:Hide() end
        local menu=b.menu
        if not menu then
            menu=CreateFrame("Frame",nil,b,"BackdropTemplate"); b.menu=menu
            menu:SetSize(math.max(220,width),math.min(12,#options)*24+12); menu:SetPoint("TOPLEFT",b,"BOTTOMLEFT",0,-2)
            menu:SetFrameStrata("DIALOG"); menu:SetFrameLevel(b:GetFrameLevel()+12); menu:EnableMouse(true)
            if menu.SetBackdrop then menu:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1}); menu:SetBackdropColor(.055,.047,.028,1); menu:SetBackdropBorderColor(.6,.46,.2,1) end
            local scroll=CreateFrame("ScrollFrame",nil,menu); scroll:SetPoint("TOPLEFT",4,-5); scroll:SetSize(menu:GetWidth()-8,menu:GetHeight()-10)
            local child=CreateFrame("Frame",nil,scroll); child:SetSize(scroll:GetWidth(),#options*24); scroll:SetScrollChild(child)
            scroll:EnableMouseWheel(true)
            scroll:SetScript("OnMouseWheel",function(self,delta) self:SetVerticalScroll(math.max(0,math.min(math.max(0,child:GetHeight()-self:GetHeight()),self:GetVerticalScroll()-delta*48))) end)
            for i,o in ipairs(options) do
                local option=o
                local ob=Button(ctx,child,option.label,child:GetWidth()-4,23); ob:SetPoint("TOPLEFT",2,-(i-1)*24)
                ob:SetScript("OnClick",function() menu:Hide(); onSelect(option.value) end)
            end
            -- Pickers are created after the page's normal child-registration
            -- pass. Include this popup so selecting TSM also lowers its layer.
            if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(menu) end
        end
        if ctx.UI then ctx.UI.ubkActivePicker=menu end
        menu:Show(); menu:Raise()
    end)
    return b
end

function T.DrawFilters(ctx,rows,state,y,goldLabel)
    local professionSet,typeSet,qualitySet={},{},{}
    for _,r in ipairs(rows) do
        for p in pairs(r.professions or {}) do professionSet[p]=true end
        typeSet[r.itemType or "Unknown"]=true; qualitySet[tostring(r.quality or "UNKNOWN")]=true
    end
    local function Options(set)
        local names={} for key in pairs(set) do names[#names+1]=key end; table.sort(names)
        local out={{value="ALL",label="All"}}; for _,key in ipairs(names) do out[#out+1]={value=key,label=key} end; return out
    end
    local qualities={{value="ALL",label="All"}}
    for i=0,7 do if qualitySet[tostring(i)] then qualities[#qualities+1]={value=tostring(i),label=(_G["ITEM_QUALITY"..i.."_DESC"] or ({[0]="Poor",[1]="Common",[2]="Uncommon",[3]="Rare",[4]="Epic",[5]="Legendary",[6]="Artifact",[7]="Heirloom"})[i])} end end
    if qualitySet.UNKNOWN then qualities[#qualities+1]={value="UNKNOWN",label="Unknown"} end
    local specs={
        {key="profession",label="Profession",options=Options(professionSet),help="Filter by professions that use or create the item in your learned TSM recipes; known material classes also supply matching professions."},
        {key="itemType",label="Type",options=Options(typeSet),help="Filter by item type: bars, ore, gems, cloth, reputation tokens, BoEs, and other available categories."},
        {key="quality",label="Quality",options=qualities,help="Filter by the quality reported by WoW. Uncached quality stays Unknown."},
        {key="gold",label=goldLabel or "Gold / unit",options={{value="ALL",label="All"},{value="UNDER1",label="Below 1g"},{value="1TO10",label="1g to <10g"},{value="10TO20",label="10g to <20g"},{value="20TO50",label="20g to <50g"},{value="50PLUS",label="50g+"},{value="UNKNOWN",label="Unavailable"}},help="Per-item gold range. Quantity never changes which range an item belongs to. Select All to include unknown values."},
    }
    local width=((ctx.UI.content:GetWidth() or 929)-28)/4
    for i,spec in ipairs(specs) do
        local s=spec
        T.Picker(ctx,ctx.UI.content,6+(i-1)*(width+4),y,width,s.label,state[s.key] or "ALL",s.options,function(value) state[s.key]=value; state.page=1; ctx.RenderPage() end,s.help)
    end
end

function T.Render(ctx,opts)
    local parent=opts.parent or ctx.UI.content
    local state=opts.state or {}; state.key=state.key or opts.columns[1].key
    local width=opts.width or parent:GetWidth()-12
    local height=opts.height or 360
    local rowHeight=opts.rowHeight or 29
    local layout,fullWidth=T.ColumnGeometry(opts.columns,width,opts.minWidth)
    local horizontal=fullWidth>width+1
    local gridHeight=height-(horizontal and 50 or 30)
    local headerHeight=30
    local perPage=math.max(1,math.floor((gridHeight-headerHeight)/rowHeight))
    local sorted=T.SortRows(opts.rows,opts.columns,state)
    local pages=math.max(1,math.ceil(#sorted/perPage)); state.page=math.max(1,math.min(pages,tonumber(state.page) or 1))
    local frame=CreateFrame("Frame",nil,parent); frame:SetPoint("TOPLEFT",opts.x or 6,opts.y or -140); frame:SetSize(width,height)
    local scroll=CreateFrame("ScrollFrame",nil,frame); scroll:SetPoint("TOPLEFT",0,0); scroll:SetSize(width,gridHeight)
    local grid=CreateFrame("Frame",nil,scroll); grid:SetSize(fullWidth,gridHeight); scroll:SetScrollChild(grid)
    Solid(grid,0,0,fullWidth,headerHeight,.13,.105,.06,1)
    for i,c in ipairs(opts.columns) do
        local col=c; local geometry=layout[i]
        local h=CreateFrame("Button",nil,grid); h:SetPoint("TOPLEFT",geometry.x,-1); h:SetSize(geometry.width,headerHeight-2)
        local label=Text(ctx,h,"GameFontNormalSmall"); label:SetPoint("LEFT",5,0); label:SetPoint("RIGHT",-5,0); label:SetJustifyH(col.align or "LEFT")
        label:SetText(col.label..(state.key==col.key and (state.ascending and " +" or " -") or "")); if label.SetWordWrap then label:SetWordWrap(false) end
        h:SetScript("OnClick",function() if state.key==col.key then state.ascending=not state.ascending else state.key=col.key; state.ascending=col.ascending~=false end; state.page=1; if opts.onChange then opts.onChange() end end)
        h:SetScript("OnEnter",function(self) Tooltip(self,col.label,(col.tooltip or "").."\nClick to sort ascending / descending. Missing values stay last. + means ascending; - means descending.") end)
        h:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end
    local visible={}; local first=(state.page-1)*perPage+1
    for index=first,math.min(#sorted,first+perPage-1) do
        local row=sorted[index]; visible[#visible+1]=row
        local n=index-first; local y=-headerHeight-n*rowHeight
        local b=CreateFrame("Button",nil,grid); b:SetPoint("TOPLEFT",0,y); b:SetSize(fullWidth,rowHeight)
        b:RegisterForClicks("LeftButtonUp","RightButtonUp")
        local bg=Solid(b,0,0,fullWidth,rowHeight,n%2==0 and .058 or .035,n%2==0 and .053 or .031,n%2==0 and .039 or .026,1)
        for i,c in ipairs(opts.columns) do
            local geo=layout[i]
            local column=c
            local actionText=column.actionText and column.actionText(row)
            if column.checkbox then
                local check=CreateFrame("CheckButton",nil,b,"UICheckButtonTemplate")
                check:SetSize(24,24); check:SetPoint("TOPLEFT",geo.x+(geo.width-24)/2,-2)
                check:SetChecked(column.checkbox(row) and true or false)
                if column.checkEnabled then check:SetEnabled(column.checkEnabled(row) and true or false) end
                check:SetScript("OnClick",function(self) column.onCheck(row,self:GetChecked() and true or false) end)
                check:SetScript("OnEnter",function(self) if opts.onEnter then opts.onEnter(self,row) end end)
                check:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
            elseif column.action and actionText then
                local action=Button(ctx,b,actionText,math.max(1,geo.width-8),rowHeight-5)
                action:SetPoint("TOPLEFT",geo.x+4,-2)
                if column.actionEnabled then action:SetEnabled(column.actionEnabled(row) and true or false) end
                action:SetScript("OnClick",function() column.action(row) end)
                action:SetScript("OnEnter",function(self) Tooltip(self,actionText,column.actionTooltip and column.actionTooltip(row) or nil) end)
                action:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
            else
                local value=column.text and column.text(row) or (column.value and column.value(row) or row[column.key])
                local fs=Text(ctx,b,"GameFontHighlightSmall"); fs:SetPoint("TOPLEFT",geo.x+5,-4); fs:SetSize(math.max(1,geo.width-10),rowHeight-8)
                fs:SetJustifyH(column.align or "LEFT"); fs:SetJustifyV("MIDDLE"); if fs.SetWordWrap then fs:SetWordWrap(false) end; fs:SetText(Available(value) and tostring(value) or "n/a")
                if column.key=="name" and row.itemString and _G.UBKItemRules then
                    fs:SetTextColor(_G.UBKItemRules.QualityColor(row.itemString))
                elseif column.color then local r,g,blue=column.color(row); if r then fs:SetTextColor(r,g,blue) end end
            end
        end
        Solid(b,0,-rowHeight+1,fullWidth,1,.22,.19,.13,1)
        b:SetScript("OnClick",function(self,button) if button=="RightButton" and opts.onRightClick then opts.onRightClick(row) elseif button=="LeftButton" and opts.onClick then opts.onClick(row) end end)
        b:SetScript("OnEnter",function(self) bg:SetVertexColor(.16,.125,.065,1); if opts.onEnter then opts.onEnter(self,row) end end)
        b:SetScript("OnLeave",function() bg:SetVertexColor(n%2==0 and .058 or .035,n%2==0 and .053 or .031,n%2==0 and .039 or .026,1); if GameTooltip then GameTooltip:Hide() end end)
    end
    -- Draw the exact same measured vertical boundaries across header and rows.
    local lineHeight=headerHeight+#visible*rowHeight
    Solid(grid,0,0,1,lineHeight); Solid(grid,fullWidth-1,0,1,lineHeight)
    for i=2,#layout do Solid(grid,layout[i].x,0,1,lineHeight) end
    Solid(grid,0,-headerHeight+1,fullWidth,1,.68,.52,.25,1)
    if #sorted==0 then local e=Text(ctx,grid); e:SetPoint("TOPLEFT",9,-headerHeight-12); e:SetWidth(width-18); e:SetText(opts.emptyText or "No items match these filters.") end
    local function Offset(value) state.offset=math.max(0,math.min(fullWidth-width,value or 0)); scroll:SetHorizontalScroll(state.offset) end
    if horizontal then
        local slider=CreateFrame("Slider",nil,frame); slider:SetOrientation("HORIZONTAL"); slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal"); slider:SetPoint("BOTTOMLEFT",10,29); slider:SetPoint("BOTTOMRIGHT",-10,29); slider:SetHeight(14)
        Solid(slider,0,-5,width-20,4,.36,.29,.17,1)
        local thumb=slider:GetThumbTexture(); if thumb then thumb:SetSize(24,16) end
        slider:SetMinMaxValues(0,fullWidth-width); slider:SetValueStep(20); slider:SetScript("OnValueChanged",function(_,value) Offset(value) end)
        slider:SetValue(state.offset or 0); scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel",function(_,delta) slider:SetValue(math.max(0,math.min(fullWidth-width,(state.offset or 0)-delta*80))) end)
    end
    Offset(state.offset or 0)
    local summary=Text(ctx,frame,"GameFontDisableSmall"); summary:SetPoint("BOTTOMLEFT",4,6); summary:SetText(string.format("%d item%s | page %d / %d%s",#sorted,#sorted==1 and "" or "s",state.page,pages,horizontal and " | Scroll sideways for more columns" or ""))
    local prev=Button(ctx,frame,"<",32,22); prev:SetPoint("BOTTOMRIGHT",-40,0); prev:SetEnabled(state.page>1)
    local nextButton=Button(ctx,frame,">",32,22); nextButton:SetPoint("BOTTOMRIGHT",-4,0); nextButton:SetEnabled(state.page<pages)
    prev:SetScript("OnClick",function() state.page=math.max(1,state.page-1); if opts.onChange then opts.onChange() end end)
    nextButton:SetScript("OnClick",function() state.page=math.min(pages,state.page+1); if opts.onChange then opts.onChange() end end)
    return {frame=frame,visibleRows=visible,total=#sorted,page=state.page,pages=pages,columns=layout,fullWidth=fullWidth}
end

function T.NameMatches(name,query)
    local function Plain(v)return tostring(v or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""):lower() end
    query=Plain(query):match("^%s*(.-)%s*$")
    return query=="" or Plain(name):find(query,1,true)~=nil
end

-- Debounced local filtering preserves typing focus/caret across page redraws.
function T.DrawSearch(ctx,parent,state,x,y,width,onChange)
    local label=Text(ctx,parent,"GameFontDisableSmall");label:SetPoint("TOPLEFT",x,y);label:SetText("Name")
    local box=CreateFrame("EditBox",nil,parent,"InputBoxTemplate")
    box:SetSize(width-96,25);box:SetPoint("TOPLEFT",x+39,y+5);box:SetAutoFocus(false);box:SetText(state.searchDraft or state.search or "")
    state.searchBox=box
    local function Commit()
        if not box:IsShown() then return end
        local value=box:GetText();if state.search==value then return end
        local focus=box.HasFocus and box:HasFocus();local cursor=box.GetCursorPosition and box:GetCursorPosition()
        state.search=value;state.searchDraft=nil;state.page=1;onChange()
        local replacement=state.searchBox
        if focus and replacement and replacement:IsShown() then replacement:SetFocus();if cursor and replacement.SetCursorPosition then replacement:SetCursorPosition(cursor) end end
    end
    box:SetScript("OnTextChanged",function(_,user)
        if not user then return end
        state.searchDraft=box:GetText()
        state.searchGeneration=(state.searchGeneration or 0)+1;local generation=state.searchGeneration
        if C_Timer and C_Timer.After then C_Timer.After(.25,function()if generation==state.searchGeneration then Commit() end end) end
    end)
    box:SetScript("OnEnterPressed",Commit)
    box:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
    box:SetScript("OnEnter",function(self)Tooltip(self,"Search by item name","Matches any part of the name across all pages, ignoring letter case. Filters combine with the selected categories. Clear returns to the unsearched list.")end)
    box:SetScript("OnLeave",function()if GameTooltip then GameTooltip:Hide()end end)
    local clear=Button(ctx,parent,"Clear",49,24);clear:SetPoint("LEFT",box,"RIGHT",6,0)
    clear:SetScript("OnClick",function()state.searchGeneration=(state.searchGeneration or 0)+1;state.search="";state.searchDraft=nil;state.page=1;onChange()end)
    return box
end

function T.BasisRange(minText,maxText)
    local function Bound(text)
        text=tostring(text or ""):match("^%s*(.-)%s*$")
        if text=="" then return nil end
        if not text:match("^%d*%.?%d+$") then return nil,"Use a nonnegative gold amount, such as 10 or 10.50." end
        local n=tonumber(text)
        if not n or n<0 or n~=n or n==math.huge then return nil,"Invalid gold boundary." end
        return math.floor(n*10000+.5)
    end
    local low,err=Bound(minText);if err then return nil,nil,err end
    local high;high,err=Bound(maxText);if err then return nil,nil,err end
    if low and high and low>high then return nil,nil,"Minimum basis must not exceed maximum basis." end
    return low,high
end
function T.RangeRows(rows,low,high)
    local out={}
    for _,row in ipairs(rows or {}) do
        if (not low and not high) or (T.Available(row.basis) and (not low or row.basis>=low) and (not high or row.basis<=high)) then out[#out+1]=row end
    end
    return out
end
function T.SelectEligible(rows)
    local selected={};local count=0
    for _,row in ipairs(rows or {})do if row.selectable then selected[row.itemString]=true;count=count+1 end end
    return selected,count
end
