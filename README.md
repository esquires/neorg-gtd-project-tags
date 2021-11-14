Provides a view of tasks grouped with a project tag.

# Overview

A more complete motivation for this project is described
[here](https://github.com/nvim-neorg/neorg/discussions/217).
In short though, this project allows users to jot down tasks anywhere in their workspace
and add a tag to place them in a project so they can be viewed as a group later.
For instance, if you have a bunch of meetings where you jot down todos
and don't have time to move them into a new workspace you may have 3
tasks in 3 different files (or 3 tasks in 3 sections in the same file) like this:

```

#project create_puzzle_app
- [ ] buy a color theory book

#project create_puzzle_app
- [ ] identify 5 areas of history to be in one puzzle theme

#project create_puzzle_app
- [ ] send an email to foobar about discussing manufacturing experience
```

Then you can enter `:Neorg gtd_project_tags` to get the following view of the `create_puzzle_app`
project as follows:

```
* create_puzzle_app (0/3 done)
   [          ] 0% done

   - buy a color theory book
   - identify 5 areas of history to be in one puzzle theme
   - send an email to foobar about discussing manufacturing experience
```

Putting the cursor on the same line as a task and hitting enter will jump you
to that task so you can view context. Of course if the tasks are next to each
other you can get the same result with a single tag

```
#project create_puzzle_app
- [ ] buy a color theory book
- [ ] identify 5 areas of history to be in one puzzle theme
- [ ] send an email to foobar about discussing manufacturing experience
```

Subprojects are also supported. For instance, you can do this:

```
#project create_puzzle_app
- [ ] buy a color theory book
- [x] identify 5 areas of history to be in one puzzle theme
- [ ] send an email to foobar about discussing manufacturing experience

# project create_puzzle_app/market_research
- [ ] buy a book on market research
- [ ] enroll in a statistics class
- [x] create a focus group
- [ ] develop a target market
```

which will render like this

```
* create_puzzle_app (2/7 done)
   [==        ] 28% done

   - buy a color theory book
   - identify 5 areas of history to be in one puzzle theme
   - send an email to foobar about discussing manufacturing experience

 ** create_puzzle_app/market_research (1/4 done)
    [==        ] 25% done

    - buy a book on market research
    - enroll in a statistics class
    - create a focus group
    - develop a target market
```

For large projects this project also supports folding by default.
One pending feature is the ability to jump to tasks as users move through the tasks list.
This is pending a feature request to neorg. Once that is fixed, branch the `cursor-moved`
will be merged.

# Installation

Installation follows typical conventions. Here is an example if using
[packer](https://github.com/wbthomason/packer.nvim):
```lua
-- packer installation
use {'esquires/gtd-project-tags'}

-- neorg configuration
require('neorg').setup {
  load = {
    ...
    ["utilities.gtd-project-tags"] = {}
  },
}
```

If you also want to bind keys to 


```
local neorg_leader = "<Leader>o"
require('neorg').setup {
  load = {
    ...
    ["utilities.gtd-project-tags"] = {}

    -- only needed if wanting to add custom keybinds
    ["core.keybinds"] = {
        config = {
            default_keybinds = true,
            neorg_leader = "<Leader>o"
        }
    },
  },
}

-- custom keybinding: https://github.com/nvim-neorg/neorg/wiki/User-Keybinds
local neorg_callbacks = require('neorg.callbacks')
neorg_callbacks.on_event("core.keybinds.events.enable_keybinds", function(_, keybinds)
	keybinds.map_event_to_mode("norg", {
      n = {
        { neorg_leader .. "p", "utilities.gtd_project_tags.views" },
      },
    }, { silent = true, noremap = true })
end)
```
