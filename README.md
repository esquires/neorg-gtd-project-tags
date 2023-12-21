This code worked with an old version of neorg but given
the gtd module was dropped, this code is obsolete.


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

Then you can enter `:Neorg gtd_project_tags 1 1 1` to get the following view of the `create_puzzle_app`
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

A couple differences from the default neorg GTD implementation:
* Supports folding by default (useful for large projects with subprojects)
* Does not require closing the view. In particular, when hitting <cr> on a task
  it will jump to the task without closing the window so it is easy to jump between
  tasks without re-running the view.

# Installation

Installation follows typical conventions. Here is an example if using
[packer](https://github.com/wbthomason/packer.nvim):
```lua
-- packer installation
use {'esquires/neorg-gtd-project-tags'}

-- neorg configuration
require('neorg').setup {
  load = {
    ...
    ["external.gtd-project-tags"] = {}
  },
}
```

You can set a custom keybind using [signals](https://github.com/nvim-neorg/neorg/wiki/User-Keybinds)
or just manually map it (e.g.):


```lua
nvim.api.nvim_command('nnoremap <Leader>p :Neorg gtd_project_tags 1 1 1')
```

# Configuration

The `Neorg gtd_project_tags` takes three arguments:

* `show_completed`: whether to show completed tasks and projects. If false, 
    task progress will not be shown to further reduce what needs to be reviewed.
* `show_future`: if false, gtd-project-tags will only show tasks that are not
  one of the following:
  - has a waiting.for tag with a due date after today
  - has a time.start after today
  - has a time.due after today (if time.start is not after today)
* `show_extra`: if true, the view will add a line for every task that has a
  time.start, a time.due, or waiting.for tag defined.
