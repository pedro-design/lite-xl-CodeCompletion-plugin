-- mod-version:3

-----------------------------------------------------------------------
-- NAME       : CodeCompletion
-- DESCRIPTION: A plugin to enable code completion using llama.cpp server
-- AUTHOR     : Pedro A. (Pedro Design)
-- GOALS      : Integrate llama cpp OpenAI like API for code completion and add suport for OpenAI models
-----------------------------------------------------------------------
-- Disclaimer :
-- This plugin is designed to enable code completion using the server file from llama.cpp
-- It provides basic functionality for triggering code completion at the time like completions and basic sugestion system
-- It calls one by one the aPI (no batching at the time)
-----------------------------------------------------------------------
-- Import required modules

local common = require "core.common"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local RootView = require "core.rootview"
local www = require "libraries.www"
-- the "keymap" module will allow us to set keybindings for our commands
local keymap = require "core.keymap"
local json = require "json"
local DocView = require "core.docview"
-- Configure plugin settings
config.plugins.codecompletion = common.merge({
  enabled = true,
	api_key="secret_key",
  model="llama",--model name
  n_predict=32,
  temperature=0.8, --llama server params
  mirostat=2,--llama server params
  stop="<im_end>",
  end_point="http://localhost:8080/completion",
  suggestions_tks= 8,
  suggestions_to_sample= 3,

  
	-- The config specification used by the settings gui
  config_spec = {
    name = "AI autocomplete",
    {
      label = "api_key",
      description = "Your api key.",
      path = "api_key",
      type = "string",
      default = "secret_key",
    },
    {
      label = "n_predict_tokens",
      description = "How many tokens generate?",
      path = "n_predict",
      type = "number",
      default = 32,

    },
    {
      label = "temperature",
      description = "Sampling temperature?",
      path = "temperature",
      type = "number",
      default = 1,

    },
    {
      label = "mirostat sampler",
      description = "Use mirostat?(0 no,1 and 2 are its versions)",
      path = "mirostat",
      type = "number",
      default = 1,

    },
    {
      label = "suggestions tokens to generate",
      description = "tokens to generate per sugestion",
      path = "suggestions_tks",
      type = "number",
      default = 8,

    },
    {
      label = "suggestions to generate",
      description = "How many suggestions generate?",
      path = "suggestions_to_sample",
      type = "number",
      default = 3,

    },
    {
      label = "stop word",
      description = "what is the stop word for the model?",
      path = "stop",
      type = "string",
      default = "<im_end>",

    },
    {
      label = "api end point",
      description = "what is the api url?",
      path = "end_point",
      type = "string",
      default = "http://localhost:8080/completion",

    },


    
  }
  
}, config.plugins.codecompletion)

local generating = false
local spiner_char = "|"
--spiner thread
core.add_thread(function()
local index = 1
        local spinner = {"|", "/", "-", "\\"}
        while true do
          if generating then
                spiner_char = spinner[index]
                index = index % #spinner + 1
          end
          coroutine.yield(0.5)
        end
      end)
local info_text ="" -- text for more information like how many requests are in queene
local loaded,r = pcall(function() core.status_view:get_item("ai-generation:working"):show() end) -- simple pcall check
if not loaded then
  core.status_view:add_item({
    predicate = function()
      return core.active_view and getmetatable(core.active_view) == DocView
    end,
    name = "ai-generation:working",
    alignment = core.status_view.Item.RIGHT,
    get_item = function()
      return {
        style.text,
        string.format("%s Working... %s",spiner_char,info_text)
      }
    end,
    position = 1,
    tooltip = "AI is generating text",
    separator = core.status_view.separator2
  })
else
    pcall(function() core.status_view:get_item("ai-generation:working"):hide() end) --if the status is loaded, just hide it
end
-- Function to complete code using an OpenAI API and calling curl
local function complete_code(prompt,dv,n,ncalls,callback_func)
  if callback_func==nil then core.error("Pass a callback function") end
  if ncalls == nil then ncalls = 1 end
  local gen_tks=config.plugins.codecompletion.n_predict
  if n  then
      gen_tks = n -- replace to the cheap call (low tokens)
  end
  local api_key = config.plugins.codecompletion.api_key
  local model = config.plugins.codecompletion.model
  local cursor_line, cursor_col = dv.doc:get_selection()
  local _i=0
  generating = true
  info_text = string.format("%d of %d completed",0,ncalls)
  core.add_thread(function()
    for call = 1, ncalls, 1 do --perform the completions 1 by 1 at the time
      core.status_view:get_item("ai-generation:working"):show()
      generating = true

      
      -- Start a new process to curl the response from the API
      local proc = process.start {
        "curl",
        "-X",
        "POST",
        "--max-time",
        "180",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Authorization: Bearer " .. api_key,
        "-H",
        "Accept: text/event-stream",
        "-H",
        "Connection: keep-alive",
        "-d",
        json.encode({
          model = model,
          prompt = prompt,
          n_predict = gen_tks, -- Maximum number of tokens in the completion
          mirostat=config.plugins.codecompletion.mirostat,
          stop=config.plugins.codecompletion.stop,
        }),
        config.plugins.codecompletion.end_point
      }

      -- Read the response from the process in a streaming manner
      local completion = ""
      local ok = true
      local counter = 0
      while ok do
        local rdbuf = proc:read_stdout()
        if not rdbuf then 
          ok = false
          break 
        end
        completion = completion .. rdbuf
        if proc:running() == false then -- stop if the curl has finished
          ok = false
        end
        coroutine.yield(0.1)
      end

      -- Parse the completion from the response
      local ok,res = pcall(function()  local result = json.decode(completion)  end)
      if not ok then
        if completion then
          core.log(completion)
        end
        core.error("Json cant be parsed, its the endpoint reacheable?")
        
        core.status_view:get_item("ai-generation:working"):hide() 
        return nil
      end
      local result = json.decode(completion)
      if result and result.content then
        -- Call the callback with the completion result
      local match = string.match(result["content"], "\n")
      if ncalls>1 then -- if sugestions are to be generated
        callback_func("sugestion_".. tostring(call)..":\n",dv)
      end
      if match then
        for line in result["content"]:gmatch("[^\n]+") do --parse new lines in response
            callback_func(line,dv)
            coroutine.yield(0.1)
          end
      else
            callback_func(result["content"],dv) -- just return all the response if not a single new line
            coroutine.yield(0.1)
      end
      info_text = string.format("%d of %d completed",call,ncalls) -- info update
      command.perform("doc:move-to-end-of-line") -- move to end of line
      core.status_view:get_item("ai-generation:working"):hide() 
      generating=false
      else
        info_text = string.format("%d of %d completed",call,ncalls)  -- info update
        core.error("Failed to complete code")--logs
        core.status_view:get_item("ai-generation:working"):hide()
        generating=false
      end
    end
  end)
end

local function finish_callback(text,dv)  -- function to call each finished completion
    command.perform("doc:move-to-next-char")
    local a,b = dv.doc:get_selection()
    dv.doc:insert(a,b," "..text.."\n" )
    command.perform("doc:move-to-end-of-line")
end

-- Command to trigger code completion
local function trigger_code_completion(dv)
   local text=""
   if dv.doc:has_selection() then-- has selected text?
      text = dv.doc:get_text(dv.doc:get_selection())
      command.perform("doc:move-to-next-char")
      command.perform("doc:move-to-end-of-line")
    else
      local line = dv.doc:get_selection() -- if not use the current line text like for an instruction
      text = dv.doc.lines[line]
  end
  local cursor_col=0
  if #text<=1 then-- the text must be non empty
    core.error("please select the code to complete")
    return ""
  end
  -- Send the selected code to the completion function
  complete_code(text,dv,nil,nil,finish_callback) -- no return because is a coreroutine
end


-- Function to toggle code completion suggestions
local function toggle_suggestions(dv)
    command.perform("doc:select-all")
    local text = dv.doc:get_text(dv.doc:get_selection())
    local p = "" -- placeholder for the function text (reads the paragraphs until the last one)
    for paragraph in text:gmatch("(.-)\n\n") do
        p=paragraph --just iterates until the last one
    end
    if #p ==0 then
        p=text -- if not uses all the context
    end
    --move to the end of line
    command.perform("doc:move-to-next-char")
    command.perform("doc:move-to-end-of-line")
     -- Send the code chunk to the completion function for sugestions,it calls 1 by 1 the API
    complete_code(p,dv,config.plugins.codecompletion.suggestions_tks,config.plugins.codecompletion.suggestions_to_sample,finish_callback)-- no return because is a coreroutine
end

-- Add command to trigger code completion
command.add("core.docview", {
  ["code-completion:trigger"] = trigger_code_completion,
  ["code-completion:toggle-suggestions"] = toggle_suggestions
})


-- Add keybindings for commands
keymap.add {
  ["alt+c"] = "code-completion:trigger",
  ["alt+s"] = "code-completion:toggle-suggestions"
}

