{
 "patcher": {
  "fileversion": 1,
  "appversion": {
   "major": 9,
   "minor": 1,
   "revision": 5,
   "architecture": "x64",
   "modernui": 1
  },
  "classnamespace": "box",
  "rect": [
   494.0,
   435.0,
   900.0,
   640.0
  ],
  "boxes": [
   {
    "box": {
     "attr": "plugin",
     "id": "obj-7",
     "maxclass": "attrui",
     "numinlets": 1,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "parameter_enable": 0,
     "patching_rect": [
      39.0,
      190.0,
      150.0,
      22.0
     ]
    }
   },
   {
    "box": {
     "id": "obj-23",
     "maxclass": "message",
     "numinlets": 2,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      431.0,
      292.0,
      33.0,
      22.0
     ],
     "text": "read"
    }
   },
   {
    "box": {
     "id": "obj-12",
     "maxclass": "toggle",
     "numinlets": 1,
     "numoutlets": 1,
     "outlettype": [
      "int"
     ],
     "parameter_enable": 0,
     "patching_rect": [
      30.0,
      73.0,
      24.0,
      24.0
     ]
    }
   },
   {
    "box": {
     "id": "obj-1",
     "linecount": 3,
     "maxclass": "comment",
     "numinlets": 1,
     "numoutlets": 0,
     "patching_rect": [
      20.0,
      10.0,
      388.0,
      47.0
     ],
     "text": "jit.gl.ffgl \u2014 host an FFGL 2.x plugin (macOS, OpenGL) inside Jitter. The plugin renders in a private GL context; frames pass through IOSurfaces."
    }
   },
   {
    "box": {
     "id": "obj-2",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 3,
     "outlettype": [
      "jit_matrix",
      "bang",
      ""
     ],
     "patching_rect": [
      20.0,
      110.0,
      159.0,
      22.0
     ],
     "text": "jit.world ffgl_help @enable 1"
    }
   },
   {
    "box": {
     "id": "obj-3",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 2,
     "outlettype": [
      "jit_gl_texture",
      ""
     ],
     "patching_rect": [
      20.0,
      256.0,
      97.0,
      22.0
     ],
     "text": "jit.gl.ffgl ffgl_help"
    }
   },
   {
    "box": {
     "id": "obj-4",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 2,
     "outlettype": [
      "",
      ""
     ],
     "patching_rect": [
      24.0,
      307.0,
      300.0,
      22.0
     ],
     "text": "jit.gl.videoplane ffgl_help @transform_reset 2"
    }
   },
   {
    "box": {
     "id": "obj-5",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 0,
     "patching_rect": [
      333.0,
      307.0,
      70.0,
      22.0
     ],
     "text": "print ffgl"
    }
   },
   {
    "box": {
     "id": "obj-6",
     "maxclass": "message",
     "numinlets": 2,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      420.0,
      60.0,
      60.0,
      22.0
     ],
     "text": "plugins"
    }
   },
   {
    "box": {
     "id": "obj-8",
     "maxclass": "message",
     "numinlets": 2,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      486.0,
      60.0,
      60.0,
      22.0
     ],
     "text": "params"
    }
   },
   {
    "box": {
     "id": "obj-9",
     "maxclass": "message",
     "numinlets": 2,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      420.0,
      216.0,
      110.0,
      22.0
     ],
     "text": "input 0 srctex"
    }
   },
   {
    "box": {
     "id": "obj-10",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 2,
     "outlettype": [
      "jit_matrix",
      ""
     ],
     "patching_rect": [
      420.0,
      330.0,
      380.0,
      22.0
     ],
     "text": "jit.movie ffgl_help @moviefile bball.mov @autostart 1 @loop 1"
    }
   },
   {
    "box": {
     "id": "obj-11",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 2,
     "outlettype": [
      "jit_gl_texture",
      ""
     ],
     "patching_rect": [
      420.0,
      370.0,
      260.0,
      22.0
     ],
     "text": "jit.gl.texture ffgl_help @name srctex"
    }
   },
   {
    "box": {
     "id": "obj-16",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 1,
     "outlettype": [
      "bang"
     ],
     "patching_rect": [
      420.0,
      20.0,
      60.0,
      22.0
     ],
     "text": "loadbang"
    }
   },
   {
    "box": {
     "id": "obj-17",
     "items": [],
     "maxclass": "umenu",
     "numinlets": 1,
     "numoutlets": 3,
     "outlettype": [
      "int",
      "",
      ""
     ],
     "parameter_enable": 0,
     "patching_rect": [
      526.0,
      162.0,
      200.0,
      22.0
     ]
    }
   },
   {
    "box": {
     "id": "obj-18",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      295.0,
      157.0,
      90.0,
      22.0
     ],
     "text": "prepend load"
    }
   },
   {
    "box": {
     "id": "obj-19",
     "maxclass": "newobj",
     "numinlets": 3,
     "numoutlets": 3,
     "outlettype": [
      "",
      "",
      ""
     ],
     "patching_rect": [
      515.0,
      93.0,
      120.0,
      22.0
     ],
     "text": "route clear plugin"
    }
   },
   {
    "box": {
     "id": "obj-20",
     "maxclass": "message",
     "numinlets": 2,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      526.0,
      123.0,
      40.0,
      22.0
     ],
     "text": "clear"
    }
   },
   {
    "box": {
     "id": "obj-21",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 2,
     "outlettype": [
      "",
      ""
     ],
     "patching_rect": [
      654.0,
      99.0,
      70.0,
      22.0
     ],
     "text": "unpack s s"
    }
   },
   {
    "box": {
     "id": "obj-22",
     "maxclass": "newobj",
     "numinlets": 1,
     "numoutlets": 1,
     "outlettype": [
      ""
     ],
     "patching_rect": [
      654.0,
      129.0,
      100.0,
      22.0
     ],
     "text": "prepend append"
    }
   },
   {
    "box": {
     "id": "obj-14",
     "linecount": 6,
     "maxclass": "comment",
     "numinlets": 1,
     "numoutlets": 0,
     "patching_rect": [
      20.0,
      340.0,
      338.0,
      87.0
     ],
     "text": "1. On load the plugin list is scanned into the menu (see README for search paths). Pick a plugin: it loads. 2. [params] dumps every parameter out the right outlet; each parameter is also a normal attribute (@name value, attrui, inspector), and [param name value] / [paramn name 0..1] work too."
    }
   },
   {
    "box": {
     "id": "obj-15",
     "linecount": 6,
     "maxclass": "comment",
     "numinlets": 1,
     "numoutlets": 0,
     "patching_rect": [
      20.0,
      440.0,
      354.0,
      87.0
     ],
     "text": "Inputs: [input <slot> <texture name>] (or a plain jit_gl_texture into the left inlet for slot 0); the name is kept when you switch plugins. Attributes: @plugin @dim @adapt @clear @sync @intarget 2d|rect @bpm @barphase. The object renders in jit.world's draw pass; set @automatic 0 to render only when banged."
    }
   }
  ],
  "lines": [
   {
    "patchline": {
     "destination": [
      "obj-11",
      0
     ],
     "source": [
      "obj-10",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-2",
      0
     ],
     "source": [
      "obj-12",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-6",
      0
     ],
     "order": 1,
     "source": [
      "obj-16",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-9",
      0
     ],
     "order": 0,
     "source": [
      "obj-16",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-18",
      0
     ],
     "source": [
      "obj-17",
      1
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-3",
      0
     ],
     "source": [
      "obj-18",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-20",
      0
     ],
     "source": [
      "obj-19",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-21",
      0
     ],
     "source": [
      "obj-19",
      1
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-17",
      0
     ],
     "source": [
      "obj-20",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-22",
      0
     ],
     "source": [
      "obj-21",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-17",
      0
     ],
     "source": [
      "obj-22",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-10",
      0
     ],
     "source": [
      "obj-23",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-19",
      0
     ],
     "order": 0,
     "source": [
      "obj-3",
      1
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-4",
      0
     ],
     "source": [
      "obj-3",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-5",
      0
     ],
     "order": 1,
     "source": [
      "obj-3",
      1
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-3",
      0
     ],
     "source": [
      "obj-6",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-3",
      0
     ],
     "source": [
      "obj-7",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-3",
      0
     ],
     "source": [
      "obj-8",
      0
     ]
    }
   },
   {
    "patchline": {
     "destination": [
      "obj-3",
      0
     ],
     "source": [
      "obj-9",
      0
     ]
    }
   }
  ],
  "autosave": 0
 }
}