--format: {unit = unit, type = "update", payload = {x = x, y = y, dir = dir}} 
update_queue = {}

movedebugflag = false
function movedebug(message)
  if movedebugflag then
    print(message)
  end
end

function doUpdate(already_added, moving_units_next)
  for _,update in ipairs(update_queue) do
    if update.reason == "update" then
      local unit = update.unit
      local x = update.payload.x
      local y = update.payload.y
      local dir = update.payload.dir
      --TODO: We need to do all applySlides either totally before or totally after doupdate.
      --Reason: Imagine two units that are ICYYYY step onto the same tile. Right now, one will slip on the other. Do we either want both to to slip or neither to slip? The former is more fun, so we should probably do all applySlides after we're done.
      applySlide(unit, x-unit.x, y-unit.y, already_added, moving_units_next);
      updateDir(unit, dir)
      movedebug("doUpdate:"..tostring(unit.name)..","..tostring(x)..","..tostring(y)..","..tostring(dir))
      moveUnit(unit, x, y)
      unit.already_moving = false
    elseif update.reason == "dir" then
      local unit = update.unit
      local dir = update.payload.dir
      unit.olddir = unit.dir
      updateDir(unit, dir);
    end
  end
  update_queue = {}
end

function doMovement(movex, movey)
  local played_sound = {}
  local slippers = {}
  local flippers = {}

  print("[---- begin turn ----]")
  print("move: " .. movex .. ", " .. movey)

  local move_stage = -1
  while move_stage < 3 do
    local moving_units = {}
    local moving_units_next = {}
    local already_added = {}
    
    for _,unit in ipairs(units) do
      unit.already_moving = false
      unit.moves = {}
    end
    
    if move_stage == -1 then
      local icy = getUnitsWithEffectAndCount("icy")
      for unit,icyness in pairs(icy) do
        for __,other in ipairs(getUnitsOnTile(unit.x, unit.y)) do
          if other.id ~= unit.id and sameFloat(unit, other) then
            table.insert(other.moves, {reason = "icy", dir = other.dir, times = icyness})
            if #other.moves > 0 and not already_added[other] then
              table.insert(moving_units, other)
              already_added[other] = true
            end
          end
        end
      end
    elseif move_stage == 0 and (movex ~= 0 or movey ~= 0) then
      local u = getUnitsWithEffectAndCount("u")
      for unit,uness in pairs(u) do
        if not hasProperty(unit, "slep") and slippers[unit.id] == nil then
          local dir = dirs8_by_offset[movex][movey]
          --If you want baba style 'when you moves, even if it fails to move, it changes direction', uncomment this.
          table.insert(unit.moves, {reason = "u", dir = dir, times = 1})
          --[[addUndo({"update", unit.id, unit.x, unit.y, unit.dir})
          updateDir(unit, dir);]]
          if #unit.moves > 0 and not already_added[unit] then
            table.insert(moving_units, unit)
            already_added[unit] = true
          end
        end
      end
    elseif move_stage == 1 then
      local isspoop = matchesRule(nil, "spoop", "?")
      for _,ruleparent in ipairs(isspoop) do
        local unit = ruleparent[2]
        local others = {}
        for nx=-1,1 do
          for ny=-1,1 do
            if (nx ~= 0) or (ny ~= 0) then
              mergeTable(others,getUnitsOnTile(unit.x+nx,unit.y+ny,nil))
            end
          end
        end
        for _,other in ipairs(others) do
          local is_spoopy = hasRule(unit, "spoop", other)
          if (is_spoopy and not hasProperty(other, "slep")) then
            spoop_dir = dirs8_by_offset[sign(other.x - unit.x)][sign(other.y - unit.y)]
            if (spoop_dir % 2 == 1 or (not hasProperty(unit, "orthongl") and not hasProperty(other, "orthongl"))) then
              addUndo({"update", other.id, other.x, other.y, other.dir})
              other.olddir = other.dir
              updateDir(other, spoop_dir)
              table.insert(other.moves, {reason = "spoop", dir = other.dir, times = 1})
              if #other.moves > 0 and not already_added[other] then
                table.insert(moving_units, other)
                already_added[other] = true
              end
            end
          end
        end
      end
      local walk = getUnitsWithEffectAndCount("walk")
      for unit,walkness in pairs(walk) do
        if not hasProperty(unit, "slep") and slippers[unit.id] == nil then
          table.insert(unit.moves, {reason = "walk", dir = unit.dir, times = walkness})
          if #unit.moves > 0 and not already_added[unit] then
            table.insert(moving_units, unit)
            already_added[unit] = true
          end
        end
      end
    elseif move_stage == 2 then
      local isyeet = matchesRule(nil, "yeet", "?");
      for _,ruleparent in ipairs(isyeet) do
        local unit = ruleparent[2]
        for __,other in ipairs(getUnitsOnTile(unit.x, unit.y)) do
          if other.id ~= unit.id and sameFloat(unit, other) then
            local is_yeeted = hasRule(unit, "yeet", other)
            if (is_yeeted) then
              table.insert(other.moves, {reason = "yeet", dir = unit.dir, times = 99})
              if #other.moves > 0 and not already_added[other] then
                table.insert(moving_units, other)
                already_added[other] = true
              end
            end
          end
        end
      end
      local go = getUnitsWithEffectAndCount("go")
      for unit,goness in pairs(go) do
        for __,other in ipairs(getUnitsOnTile(unit.x, unit.y)) do
          if other.id ~= unit.id and sameFloat(unit, other) then
            table.insert(other.moves, {reason = "go", dir = unit.dir, times = goness})
            if #other.moves > 0 and not already_added[other] then
              table.insert(moving_units, other)
              already_added[other] = true
            end
          end
        end
      end
    end
    
    --[[
Simultaneous movement algorithm, basically a simple version of Baba's:
1) Make a list of all things that are moving this stage, moving_units.
2a) Try to move each of them once. For each success, move it to moving_units_next and set it already_moving with one less move point and an update queued. If there was at least one success, repeat 2 until there are no successes. (During this process, things that are currently moving are considered intangible in canMove.)
2b) But wait, we're still not done! Flip all walkers that failed to flip, then continue until we once again have no successes. (Flipping still only happens once per turn.)
2c) Finally, if we had at least one success, everything left is moved to moving_units_next with one less move point and we repeat from 2a). If we had no successes, the stage is totally resolved. doupdate() and unset all current_moving.
3) when SLIDE/LAUNCH/BOUNCE exists, we'll need to figure out where to insert it... but if it's like baba, it goes after the move succeeds but before do_update(), and it adds either another update or another movement as appropriate.

ALTERNATE MOVEMENT ALGORITHM that would preserve properties like 'x is move and stop pulls apart' and is mostly move order independent:
1) Do it as before, except instead of moving a unit when you discover it can be moved, mark it and wait until the inner loop is over.
2) After the inner loop is over, move all the things that you marked.

But if we want to go a step further and e.g. make it so X IS YOU AND PUSH lets you catapult one of yourselves two tiles, we have to go a step further and stack up all of the movement that would occur instead of making it simultaneous and override itself.

But if we do THIS, then we can now attempt to move to different destination tiles than we tried the first time around. So we have to re-evaluate the outcome of that by calling canMove again. And if that new movement can also cause push/pull/sidekik/slide/launch, then we have to recursively check everything again, and it's unclear what order things should evaluate in, and etc.

It is probably possible to do, but lily has decided that it's not important enough if it's difficult, so we shall stay with simultanous movement for now.
]]
    --loop_stage and loop_tick are infinite loop detection.
    local loop_stage = 0
    local successes = 1
    --Stage loop continues until nothing moves in the inner loop, and does a doUpdate after each inner loop, to allow for multimoves to exist.
    while (#moving_units > 0 and successes > 0) do 
      if (loop_stage > 1000) then
        print("movement infinite loop! (1000 attempts at a stage)")
        destroyLevel("infloop");
      end
      movedebug("loop_stage:"..tostring(loop_stage))
      successes = 0
      local loop_tick = 0
      loop_stage = loop_stage + 1
      local something_moved = true
      --Tick loop tries to move everything at least once, and gives up if after an iteration, nothing can move. (It also tries to do flips to see if that helps.) (Incrementing loop_tick once is a 'sub-tick'. Calling doUpdate and incrementing loop_stage is a 'tick'. Incrementing move_stage is a 'stage'.)
      while (something_moved) do
         if (loop_tick > 1000) then
          print("movement infinite loop! (1000 attempts at a single tick)")
          destroyLevel("infloop");
        end
        movedebug("loop_tick:"..tostring(loop_tick))
        local remove_from_moving_units = {}
        local has_flipped = false
        something_moved = false
        loop_tick = loop_tick + 1
        for _,unit in ipairs(moving_units) do
          while #unit.moves > 0 and unit.moves[1].times <= 0 do
            table.remove(unit.moves, 1)
          end
          if #unit.moves > 0 and not unit.removed then
            local data = unit.moves[1]
            local dir = data.dir
            local dpos = dirs8[dir]
            local dx,dy = dpos[1],dpos[2]
            --dx/dy collation logic for copykat moves
            if (data.reason == "copkat") then
              dx = sign(data.dx)
              dy = sign(data.dy)
              if (dx == 0 and dy == 0) then
                data.times = data.times - 1;
                while #unit.moves > 0 and unit.moves[1].times <= 0 do
                  table.remove(unit.moves, 1)
                end
                break
              else
                dir = dirs8_by_offset[dx][dy];
                data.dir = dir
              end
            end
            movedebug("considering:"..unit.name..","..dir)
            local success,movers,specials = canMove(unit, dx, dy, dir, true, false, nil, data.reason)
            for _,special in ipairs(specials) do
              doAction(special)
            end
            if success then
              something_moved = true
              successes = successes + 1
              
              for k = #movers, 1, -1 do
                moveIt(movers[k].unit, movers[k].dx, movers[k].dy, movers[k].dir, data, false, already_added, moving_units, moving_units_next, slippers)
              end
              --Patashu: only the mover itself pulls, otherwise it's a mess. stuff like STICKY/STUCK will require ruggedizing this logic.
              --Patashu: TODO: Doing the pull right away means that in a situation like this: https://cdn.discordapp.com/attachments/579519329515732993/582179745006092318/unknown.png the pull could happen before the bounce depending on move order. To fix this... I'm not sure how Baba does this? But it's somewhere in that mess of code.
              doPull(unit, dx, dy, dir, data, already_added, moving_units, moving_units_next,  slippers)
              
              --we made our move this iteration, wait until the next iteration to move again
              remove_from_moving_units[unit] = true;
              --add to moving_units_next if we have another pending move
              data.times = data.times - 1;
              while #unit.moves > 0 and unit.moves[1].times <= 0 do
                table.remove(unit.moves, 1)
              end
              if #unit.moves > 0 then
                table.insert(moving_units_next, unit);
              end
            end
          else
            remove_from_moving_units[unit] = true;
          end
        end
        --do flips if we failed to move anything
        if (not something_moved and not has_flipped) then
          --TODO: CLEANUP: This is getting a little duplicate-y.
          for _,unit in ipairs(moving_units) do
            while #unit.moves > 0 and unit.moves[1].times <= 0 do
              table.remove(unit.moves)
            end
            if #unit.moves > 0 and not unit.removed and unit.moves[1].times > 0 then
              local data = unit.moves[1]
              if data.reason == "walk" and flippers[unit.id] ~= true and not hasProperty(unit, "stubbn") then
                dir = rotate8(data.dir); data.dir = dir;
                addUndo({"update", unit.id, unit.x, unit.y, unit.dir})
                table.insert(update_queue, {unit = unit, reason = "update", payload = {x = unit.x, y = unit.y, dir = data.dir}})
                flippers[unit.id] = true
                something_moved = true
                successes = successes + 1
                remove_from_moving_units[unit] = true;
                table.insert(moving_units_next, unit);
              end
            end
          end
          has_flipped = true;
        end
        for i=#moving_units,1,-1 do
          local unit = moving_units[i];
          if (remove_from_moving_units[unit]) then
            table.remove(moving_units, i);
            already_added[unit] = false;
          end
        end
      end
      --Patashu: If we want to satisfy the invariant 'when multiple units move simultaneously, if some of them can't move the first time around, they lose their chance to move', then uncomment this. This lets you do things like bab be u & bounded no1 and have a blob of babs break up (since initially only the front row can move).
      --[[for i=#moving_units,1,-1 do
        local unit = moving_units[i];
        if #unit.moves > 0 and unit.moves[1].times > 0 then
          unit.moves[1].times = unit.moves[1].times - 1;
          while #unit.moves > 0 and unit.moves[1].times <= 0 do
            table.remove(unit.moves)
          end
          if #unit.moves == 0 then
            table.remove(moving_units, i);
          end
        end
      end]]--
      doUpdate(already_added, moving_units_next)
      for _,unit in ipairs(moving_units_next) do
        movedebug("re-added:"..unit.name)
        table.insert(moving_units, unit);
        already_added[unit] = true;
      end
      moving_units_next = {}
    end
    move_stage = move_stage + 1
  end
  parseRules()
  fallBlock()
  updateUnits(false, true)
  parseRules()
  convertUnits()
  updateUnits(false, false)
  parseRules()
end

function doAction(action)
  local action_name = action[1]
  if action_name == "open" then
    playSound("break", 0.5)
    playSound("unlock", 0.6)
    local victims = action[2]
    for _,unit in ipairs(victims) do
      addParticles("destroy", unit.x, unit.y, {237,226,133})
      if not hasProperty(unit, "protecc") then
        unit.removed = true
        unit.destroyed = true
      end
    end
  elseif action_name == "weak" then
    playSound("break", 0.5)
    local victims = action[2]
    for _,unit in ipairs(victims) do
      addParticles("destroy", unit.x, unit.y, unit.color)
      --no protecc check because it can't safely be prevented here (we might be moving OoB)
      unit.removed = true
      unit.destroyed = true
    end
  end
end

function moveIt(mover, dx, dy, dir, data, pulling, already_added, moving_units, moving_units_next, slippers)
  if not mover.removed then
    queueMove(mover, dx, dy, dir, false);
    --applySlide(mover, dx, dy, already_added, moving_units_next);
    applySwap(mover, dx, dy);
    --finishing a slip locks you out of U/WALK for the rest of the turn
    if (data.reason == "icy") then
      slippers[mover.id] = true
    end
    --add SIDEKIKERs to move in the next sub-tick
    for __,sidekiker in ipairs(findSidekikers(mover, dx, dy)) do
      local currently_moving = false
      for _,mover2 in ipairs(moving_units) do
        if mover2 == sidekiker then
          currently_moving = true
          break
        end
      end
      if not currently_moving then
        table.insert(sidekiker.moves, {reason = "sidekik", dir = mover.dir, times = 1}) --TODO: dx/dy, dir and mover.dir could possibly all be different, explore advanced movement interactions with sidekik and wrap, portal, stubborn
        table.insert(moving_units, sidekiker) --Patashu: I think moving_units is correct (since it should happen 'at the same time' like a push or pull) but maybe changing this to moving_units_next will fix a bug in the future...?
        already_added[sidekiker] = true
      end
    end
    --add COPYKATs to move in the next tick
    --basically: if they're currently copying, ignore the first move we find. if we find a non-ignored move, add to it. else, add a new move.
    --On that new move, we add up all dx and dy. The final dx and dy will be the sign (so limited to -1/1) of its dx and dy.
    for copykat,_ in pairs(findCopykats(mover)) do
      local currently_moving = false
      for _,mover2 in ipairs(moving_units) do
        if mover2 == copykat then
          currently_moving = true
          break
        end
      end
      local found = false
      for i,move in ipairs(copykat.moves) do
        if move.reason == "copkat" then
          if currently_moving then
            currently_moving = false
          else
            move.dx = move.dx + dx
            move.dy = move.dy + dy
            movedebug("copykat collate:"..tostring(move.dx)..","..tostring(move.dy))
            found = true
            break
          end
        end
      end
      if not found then
        table.insert(copykat.moves, {reason = "copkat", dir = mover.dir, times = 1, dx = dx, dy = dy}) --TODO: dx/dy, dir and mover.dir could possibly all be different, explore advanced movement interactions with copykat and wrap, portal, stubborn
        table.insert(moving_units_next, copykat)
        already_added[copykat] = true
      end
    end
  end
end

function queueMove(mover, dx, dy, dir, priority)
  addUndo({"update", mover.id, mover.x, mover.y, mover.dir})
  mover.olddir = mover.dir
  updateDir(mover, dir)
  movedebug("moving:"..mover.name..","..tostring(mover.id)..","..tostring(mover.x)..","..tostring(mover.y)..","..tostring(dx)..","..tostring(dy))
  mover.already_moving = true;
  table.insert(update_queue, (priority and 1 or (#update_queue + 1)), {unit = mover, reason = "update", payload = {x = mover.x + dx, y = mover.y + dy, dir = mover.dir}})
end

function applySlide(mover, dx, dy, already_added, moving_units_next)
  --Before we add a new LAUNCH/SLIDE move, deleting all existing LAUNCH/SLIDE moves, so that if we 'move twice in the same tick' (such as because we're being pushed or pulled while also sliding) it doesn't stack. (this also means e.g. SLIDE & SLIDE gives you one extra move at the end, rather than multiplying your movement.)
  local did_clear_existing = false
  --LAUNCH will take precedence over SLIDE, so that puzzles where you move around launchers on an ice rink will behave intuitively.
  local did_launch = false
   --we haven't actually moved yet, so check the tile we will be on
  for _,v in ipairs(getUnitsOnTile(mover.x+dx, mover.y+dy)) do
    if (sameFloat(mover, v) and not v.already_moving) then
      local launchness = countProperty(v, "goooo");
      if (launchness > 0) then
        if (not did_clear_existing) then
          for i = #mover.moves,1,-1 do
            if mover.moves[i].reason == "goooo" or mover.moves[i].reason == "icyyyy" then
              table.remove(mover.moves, i)
            end
          end
          did_clear_existing = true
        end
        --the new moves will be at the start of the unit's moves data, so that it takes precedence over what it would have done next otherwise
        --TODO: CLEANUP: Figure out a nice way to not have to pass this around/do this in a million places.
        movedebug("launching:"..mover.name..","..v.dir)
        table.insert(mover.moves, 1, {reason = "goooo", dir = v.dir, times = launchness})
        if not already_added[mover] then
          movedebug("did add launcher")
          table.insert(moving_units_next, mover)
          already_added[mover] = true
        end
        did_launch = true
      end
    end
  end
  if (did_launch) then
    return
  end
  for _,v in ipairs(getUnitsOnTile(mover.x+dx, mover.y+dy)) do
    if (sameFloat(mover, v) and not v.already_moving) then
      local slideness = countProperty(v, "icyyyy");
      if (slideness > 0) then
        if (not did_clear_existing) then
          for i = #mover.moves,1,-1 do
            if mover.moves[i].reason == "goooo" or mover.moves[i].reason == "icyyyy" then
              table.remove(mover.moves, i)
            end
          end
          did_clear_existing = true
        end
        movedebug("sliding:"..mover.name..","..mover.dir)
        table.insert(mover.moves, 1, {reason = "icyyyy", dir = mover.dir, times = slideness})
        if not already_added[mover] then
          movedebug("did add slider")
          table.insert(moving_units_next, mover)
          already_added[mover] = true
        end
      end
    end
  end
end

function applySwap(mover, dx, dy)
  --we haven't actually moved yet, same as applySlide
  --two priority related things:
  --1) don't swap with things that are already moving, to prevent move order related behaviour
  --2) swaps should occur before any other kind of movement, so that the swap gets 'overriden' by later, more intentional movement e.g. in a group of swap and you moving things, or a swapper pulling boxen behind it
  --[[addUndo({"update", unit.id, unit.x, unit.y, unit.dir})]]--
  local swap_mover = hasProperty(mover, "behin u");
  local did_swap = false
  for _,v in ipairs(getUnitsOnTile(mover.x+dx, mover.y+dy)) do
    --if not v.already_moving then --this made some things move order dependent, so taking it out
      local swap_v = hasProperty(v, "behin u");
      --Don't swap with non-swap empty.
      if ((swap_mover and v.name ~= "no1") or swap_v) then
        queueMove(v, -dx, -dy, swap_v and rotate8(mover.dir) or v.dir, true);
        did_swap = true
      end
    end
  --end
  if (swap_mover and did_swap) then
     table.insert(update_queue, {unit = mover, reason = "dir", payload = {dir = rotate8(mover.dir)}})
  end
end

function findSidekikers(unit,dx,dy)
  local result = {}
  if hasProperty(unit, "shy") then
    return result;
  end
  local x = unit.x;
  local y = unit.y;
  dx = sign(dx);
  dy = sign(dy);
  local dir = dirs8_by_offset[dx][dy];
  
  local dir90 = (dir + 2 - 1) % 8 + 1;
  for i = 1,2 do
    local curdir = (dir90 + 4*i - 1) % 8 + 1;
    local curx = x+dirs8[curdir][1];
    local cury = y+dirs8[curdir][2];
    for _,v in ipairs(getUnitsOnTile(curx, cury)) do
      if hasProperty(v, "sidekik") then
        table.insert(result, v);
      end
    end
  end
  
  --Testing a new feature: sidekik & come pls objects follow you even on diagonals, to make them very hard to get away from in bab 8 way geometry, while just sidekik objects behave as they are right now so they're appropriate for 4 way geometry or being easy to walk away from
  local dir45 = (dir + 1 - 1) % 8 + 1;
  for i = 1,4 do
    local curdir = (dir45 + 2*i - 1) % 8 + 1;
    local curx = x+dirs8[curdir][1];
    local cury = y+dirs8[curdir][2];
    for _,v in ipairs(getUnitsOnTile(curx, cury)) do
      if hasProperty(v, "sidekik") and hasProperty(v, "come pls") and not hasProperty(v, "orthognl") then
        table.insert(result, v);
      end
    end
  end
  
  return result;
end

function findCopykats(unit)
  local result = {}
  local iscopykat = matchesRule("?", "copkat", unit);
  for _,ruleparent in ipairs(iscopykat) do
    local copykats = findUnitsByName(ruleparent[1][1])
    local copykat_conds = ruleparent[1][4][1]
    for _,copykat in ipairs(copykats) do
      if testConds(copykat, copykat_conds) then
        result[copykat] = true;
      end
    end
  end
  return result
end

function doPull(unit,dx,dy,dir,data, already_added, moving_units, moving_units_next, slippers)
  local x = unit.x;
  local y = unit.y;
  local something_moved = not hasProperty(unit, "shy")
  while (something_moved) do
    something_moved = false
    --TODO: Pull doesn't use WRAP/PORTAL yet.
    x = x - dx;
    y = y - dy;
    for _,v in ipairs(getUnitsOnTile(x, y)) do
      if hasProperty(v, "come pls") then
        local success,movers,specials = canMove(v, dx, dy, dir, true) --TODO: I can't remember why pushing is set but pulling isn't LOL, but if nothing's broken then shrug??
        for _,special in ipairs(specials) do
          doAction(special)
        end
        if (success) then
          --unit.already_moving = true
          something_moved = something_moved or not hasProperty(mover, "shy")
          for _,mover in ipairs(movers) do
            moveIt(mover.unit, mover.dx, mover.dy, mover.dir, data, true, already_added, moving_units, moving_units_next, slippers)
          end
        end
      end
    end
  end
end

function fallBlock()
  --TODO: If we have multiple gravity directions, then we probably want a simultaneous single step algorithm to resolve everything neatly.
  --TODO: If anything can change a faller's direction or position mid-flight (wrap/portal anyone?) then we need infinite loop protection here.
  local fallers = getUnitsWithEffect("haet skye")
  table.sort(fallers, function(a, b) return a.y > b.y end )
  
  for _,unit in ipairs(fallers) do
    local caught = false
	
    addUndo({"update", unit.id, unit.x, unit.y, unit.dir})
    local loop_fall = 0
    while (caught == false) do
      local loop_fall = loop_fall + 1;
      if (loop_stage > 1000) then
        print("movement infinite loop! (1000 attempts at a faller)")
        destroyLevel("infloop");
      end
      local catchers = getUnitsOnTile(unit.x,unit.y+1)
      if not inBounds(unit.x,unit.y+1) then
        caught = true
      end
      for _,on in ipairs(catchers) do
        if not canMove(unit, 0, 1, 3, false, false, nil, "haet skye") then
          caught = true
        end
      end
      
      if caught == false then
        moveUnit(unit,unit.x,unit.y+1)
      end
    end
  end
end

function doZip(unit)
  if not canMove(unit, 0, 0, -1, false, false, unit.name, "zip") then
    --try to zip to the tile behind us - this is usually elegant, since we probably just left that tile. if that fails, try increasingly larger squares around our current position until we give up. prefer squares closer to the tile behind us, arbitrarily break ties via however table.sort and the order we put tiles into it decides to do it!
    local dx = -dirs8[unit.dir][1]
    local dy = -dirs8[unit.dir][2]
    if canMove(unit, dx, dy, -1, false, false, unit.name, "zip") then
      addUndo({"update", unit.id, unit.x, unit.y, unit.dir})
      moveUnit(unit,unit.x+dx,unit.y+dy)
      return
    end
    
    local orig = {x = dx, y = dy}
    start_radius = 1
    end_radius = 5
    for radius = start_radius, end_radius do
      places = {}
      for dx = -radius, radius do
        for dy = -radius, radius do
          table.insert(places, {x = dx, y = dy})
        end
      end
      table.sort(places, function(a, b) return euclideanDistance(a, orig) < euclideanDistance(b, orig) end )
      for _,place in ipairs(places) do
        local dx = place.x
        local dy = place.y
        --TODO: Fall doesn't use WRAP/PORTAL yet.
        if canMove(unit, dx, dy, -1, false, false, unit.name, "zip") then
          addUndo({"update", unit.id, unit.x, unit.y, unit.dir})
          moveUnit(unit,unit.x+dx,unit.y+dy)
          return
        end
      end
    end
  end
end

--for use with wrap and portal. portals can change the facing dir, and facing dir can already be different from dx and dy, so we need to keep track of everything.
function getNextTile(unit,dx,dy,dir)
  local move_dir = dirs8_by_offset[sign(dx)][sign(dy)]
  local px, py = unit.x+dx, unit.y+dy
  --we have to loop because a portal might put us oob, which wraps and puts us in another portal, which puts us oob... etc
  local did_update = true
  local loop_portal = 0
  while (did_update) do
    local pxold, pyold = px, py
    did_update = false
    loop_portal = loop_portal + 1
    if loop_portal > 1000 then
      print("movement infinite loop! (1000 attempts at wrap/portal)")
      destroyLevel("infloop");
    end
    print(tostring(px)..","..tostring(py))
    px, py = doWrap(unit, px, py);
    print(tostring(px)..","..tostring(py))
    px, py, move_dir, dir = doPortal(unit, px, py, move_dir, dir)
    print(tostring(px)..","..tostring(py))
    if (px ~= pxold or py ~= pyold) then
      did_update = true
    end
  end
  dx = dirs8[move_dir][1];
  dy = dirs8[move_dir][2];
  return dx, dy, dir, px, py
end

function doWrap(unit, px, py)
  if hasProperty(unit, "go arnd") then
    if (px < 0) then
      px = px + mapwidth
    elseif (px >= mapwidth) then
      px = px - mapwidth
    end
    if (py < 0) then
      py = py + mapheight
    elseif (py >= mapheight) then
      py = py - mapheight
    end
  end
  return px, py
end

--TODO: facing dir is not altered by portaling
--TODO: there's a graphical glitch where undoing doesn't seem to work, because of the tween I used
function doPortal(unit, px, py, move_dir, dir)
  if not inBounds(px,py) or rules_with["poor toll"] == nil then
    return px, py, move_dir, dir;
  else
    --arbitrarily pick the first paired portal we find while iterating - can't think of a more 'simultaneousy' logic
    --TODO: I could make portals go backwards/forwards twice/etc depending on property count. maybe later?
    for _,v in ipairs(getUnitsOnTile(px, py, nil, false)) do
      if hasProperty(v, "poor toll") then
        local portal_rules = matchesRule(v.name, "be", "poor toll");
        local portals_direct = {};
        local portals = {};
        local portal_index = -1;
        for _,rule in ipairs(portal_rules) do
          for _,s in ipairs(findUnitsByName(v.name)) do
            if testConds(s, rule[1][4][1]) then
              portals_direct[s] = true
            end
          end
        end
        print(dump(portals_direct));
        for p,_ in pairs(portals_direct) do
          table.insert(portals, p);
        end
        table.sort(portals, readingOrderSort)
        print(dump(portals));
        --find our place in the list
        for pk,pv in ipairs(portals) do
          if pv == v then
            portal_index = pk;
            break
          end
        end
        --did I ever mention I hate 1 indexed arrays?
        local dest_index = ((portal_index + 1 - 1) % #portals) + 1;
        local dest_portal = portals[dest_index];
        local dir1 = v.dir
        local dir2 = dest_portal.dir
        move_dir = move_dir > 0 and dirAdd(move_dir, dirDiff(dir1, dir2)) or 0
        dir = dir > 0 and dirAdd(dir, dirDiff(dir1, dir2)) or 0
        local dx, dy = 0, 0;
        if (move_dir > 0) then
          dx = dirs8[move_dir][1];
          dy = dirs8[move_dir][2];
        end
        px = dest_portal.x + dx;
        py = dest_portal.y + dy;
        return px, py, move_dir, dir;
      end
    end
  end
  return px, py, move_dir, dir;
end

function dirDiff(dir1, dir2)
  if dir1 <= dir2 then
    return dir2 - dir1
  else
    return dir2 - (dir1+8)
  end
end

function dirAdd(dir1, diff)
  dir1 = dir1 + diff;
  while dir1 < 0 do
    dir1 = dir1  + 8
  end
  while dir1 > 8 do
    dir1 = dir1 - 8
  end
  return dir1
end

--stubborn units will try to slide around an obstacle in their way. everyone else just passes through!
--stubbornness increases with amount of stacks:
--1 stack: 45 degree angles for diagonal moves only
--2 stacks: 45 degree angles for all moves
--3 stacks: up to 90 degrees
--4 stacks: up to 135 degrees
--5 stacks: up to 180 degrees (e.g. all directions)
function canMove(unit,dx,dy,dir,pushing_,pulling_,solid_name,reason,push_stack_)
  local success, movers, specials = canMoveCore(unit,dx,dy,dir,pushing_,pulling_,solid_name,reason,push_stack_);
  if success then
    return success, movers, specials;
  elseif dir > 0 then
    local stubbn = countProperty(unit, "stubbn")
    if stubbn > 0 and (dir % 2 == 0) or stubbn > 1 then
      for i = 1,clamp(stubbn-1, 1, 4) do
        local stubborndir1 = ((dir+i-1)%8)+1
        local stubborndir2 = ((dir-i-1)%8)+1
        local success1, movers1, specials1 = canMoveCore(unit,dirs8[stubborndir1][1],dirs8[stubborndir1][2],dir,pushing_,pulling_,solid_name,reason,push_stack_);
        local success2, movers2, specials2 = canMoveCore(unit,dirs8[stubborndir2][1],dirs8[stubborndir2][2],dir,pushing_,pulling_,solid_name,reason,push_stack_);
        if (success1 and not success2) then
          return success1,movers1,specials1
        elseif (success2 and not success1) then
          return success2,movers2,specials2
        elseif (success1 and success2) then --both succeeded - return whichever requires less effort
          if #movers1 <= #movers2 then
            return success1,movers1,specials1
          else
            return success2,movers2,specials2
          end
        end
      end
    end
  end
  return success, movers, specials;
end

function canMoveCore(unit,dx,dy,dir,pushing_,pulling_,solid_name,reason,push_stack_)
  --prevent infinite push loops by returning false if a push intersects an already considered unit
  local push_stack = push_stack_ or {}
  
  if (push_stack[unit] == true) then
    return false,{},{}
  end
  
  local pushing = false
  if (pushing_ ~= nil and not hasProperty(unit, "shy")) then
		pushing = pushing_
	end
  --TODO: Patashu: this isn't used now but might be in the future??
  local pulling = false
	if (pulling_ ~= nil and not hasProperty(unit, "shy")) then
		pulling = pulling_
	end
  
  local dx, dy, dir, x, y = getNextTile(unit, dx, dy, dir);
  
  local movers = {}
  local specials = {}
  table.insert(movers, {unit = unit,dx = x-unit.x,dy = y-unit.y,dir = dir})
  
  if not inBounds(x,y) then
    if hasProperty(unit, "ouch") and not hasProperty(unit, "protecc") and (reason ~= "walk" or hasProperty(unit, "stubbn")) then
      table.insert(specials, {"weak", {unit}})
      return true,movers,specials
    end
    return false,{},{}
  end

  if hasProperty(unit, "diagnal") and (not hasProperty(unit, "orthongl")) and (dx == 0 or dy == 0) then
    return false,movers,specials
  end
  if hasProperty(unit, "orthongl") and (not hasProperty(unit, "diagnal")) and (dx ~= 0 and dy ~= 0) then
    return false,movers,specials
  end
  
  local tileid = x + y * mapwidth
  
  --bounded: if we're bounded and there are no units in the destination that satisfy a bounded rule, AND there's no units at our feet that would be moving there to carry us, we can't go
  local isbounded = matchesRule(unit, "bounded", "?");
  if (#isbounded > 0) then
    local success = false
    for _,v in ipairs(getUnitsOnTile(x, y, nil, false)) do
      if hasRule(unit, "bounded", v) then
        success = true
        break
      end
    end
    if not success then
      for _,update in ipairs(update_queue) do
        if update.reason == "update" then
          local unit2 = update.unit2
          local x2 = update.payload.x
          local y2 = update.payload.y
          if x2 == x and y2 == y and hasRule(unit, "bounded", unit2) then
            success = true
            break
          end
        end
      end
    end
    if not success then
      return false,{},{}
    end
  end
  
  local nedkee = hasProperty(unit, "ned kee")
  local fordor = hasProperty(unit, "for dor")
  local swap_mover = hasProperty(unit, "behin u")
  
  --normal checks
  for _,v in ipairs(getUnitsOnTile(x, y, nil, false)) do
    --Patashu: treat moving things as intangible in general. also, ignore ourselves for zip purposes
    if (v ~= unit and not v.already_moving) then
      local stopped = false
      if (v.name == solid_name) then
        return false,movers,specials
      end
      local would_swap_with = swap_mover or hasProperty(v, "behin u") and pushing
      --pushing a key into a door automatically works
      if (fordor and hasProperty(v, "ned kee")) or (nedkee and hasProperty(v, "for dor")) then
        table.insert(specials, {"open", {unit, v}})
        return true,movers,specials
      end
      --New FLYE mechanic, as decreed by the bab dictator - if you aren't sameFloat as a push/pull/sidekik, you can enter it.
      if hasProperty(v, "go away") and not would_swap_with then
        if pushing then
          push_stack[unit] = true
          local success,new_movers,new_specials = canMove(v, dx, dy, dir, pushing, pulling, solid_name, "go away", push_stack)
          push_stack[unit] = nil
          for _,special in ipairs(new_specials) do
            table.insert(specials, special)
          end
          if success then
            for _,mover in ipairs(new_movers) do
              table.insert(movers, mover)
            end
          else
            stopped = stopped or sameFloat(unit, v)
          end
        else
          stopped = stopped or sameFloat(unit, v)
        end
      end
      
      --if/elseif chain for everything that sets stopped to true if it's true - no need to check the remainders after all!
      if hasProperty(v, "no go") then --Things that are STOP stop being PUSH or PULL, unlike in Baba. Also unlike Baba, a wall can be floated across if it is not tall!
        stopped = stopped or sameFloat(unit, v)
      elseif hasProperty(v, "sidekik") and not hasProperty(v, "go away") and not would_swap_with then
        stopped = stopped or sameFloat(unit, v)
      elseif hasProperty(v, "come pls") and not hasProperty(v, "go away") and not would_swap_with and not pulling then
        stopped = stopped or sameFloat(unit, v)
      elseif hasProperty(v, "go my wey") and goMyWeyPrevents(v.dir, dx, dy) then
        stopped = true
      end
      
      --if thing is ouch, it will not stop things - similar to Baba behaviour. But check safe and float as well.
      --Funny buggy looking interaction (that also happens in Baba): You can push the 'ouch' of 'wall be ouch' onto a solid wall. This could be fixed by making walking onto an ouch wall destroy it as a reaction to movement, like how keys/doors are destroyed as a reaction to movement right now.
      if hasProperty(v, "ouch") and not hasProperty(v, "protecc") and sameFloat(unit, v) then
        stopped = false
      end
      --if a weak thing tries to move and fails, destroy it. movers don't do this though.
      if stopped and hasProperty(unit, "ouch") and not hasProperty(unit, "protecc") and (reason ~= "walk" or not hasProperty(unit, "stubbn")) then
        table.insert(specials, {"weak", {unit = unit,dx = dx,dy = dy,dir = dir}})
        return true,movers,specials
      end
      if stopped then
        return false,movers,specials
      end
    end
  end
  
  --go my wey DOES Not also prevents things from leaving them against their direction
  --[[for _,v in ipairs(getUnitsOnTile(unit.x, unit.y, nil, false)) do
    if hasProperty(v, "go my wey") and goMyWeyPrevents(v.dir, dx, dy) then
      return false,movers,specials
    end
  end]]--

  return true,movers,specials
end

function goMyWeyPrevents(dir, dx, dy)
  dx = sign(dx)
  dy = sign(dy)
  return
     (dir == 1 and dx == -1) or (dir == 2 and (dx == -1 or dy == -1) and (dx ~=  1 and dy ~=  1))
  or (dir == 3 and dy == -1) or (dir == 4 and (dx ==  1 or dy == -1) and (dx ~= -1 and dy ~=  1))
  or (dir == 5 and dx ==  1) or (dir == 6 and (dx ==  1 or dy ==  1) and (dx ~= -1 and dy ~= -1)) 
  or (dir == 7 and dy ==  1) or (dir == 8 and (dx == -1 or dy ==  1) and (dx ~=  1 and dy ~= -1))
end
