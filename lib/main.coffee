{CompositeDisposable, Disposable} = require 'atom'

Merlin = null
Buffer = null
TypeView = null
SelectionView = null
RenameView = null

module.exports =
  merlin: null
  subscriptions: null
  buffers: {}

  typeViews: {}
  selectionViews: {}

  latestType: null

  occurrences: null

  positions: []

  indentRange: null

  activate: (state) ->
    Merlin = require './merlin'
    Buffer = require './buffer'
    TypeView = require './type-view'
    SelectionView = require './selection-view'

    @merlin = new Merlin

    @subscriptions = new CompositeDisposable

    @subscriptions.add atom.config.onDidChange 'ocaml-merlin.merlinPath', =>
      @restartMerlin()

    target = 'atom-text-editor[data-grammar="source ocaml"]'
    @subscriptions.add atom.commands.add target,
      'ocaml-merlin:show-type': => @showType()
      'ocaml-merlin:shrink-type': => @shrinkType()
      'ocaml-merlin:expand-type': => @expandType()
      'ocaml-merlin:close-bubble': => @closeType()
      'ocaml-merlin:insert-latest-type': => @insertType()
      'ocaml-merlin:destruct': => @destruct()
      'ocaml-merlin:next-occurrence': => @getOccurrence(1)
      'ocaml-merlin:previous-occurrence': => @getOccurrence(-1)
      'ocaml-merlin:go-to-declaration': => @goToDeclaration('ml')
      'ocaml-merlin:go-to-type-declaration': => @goToDeclaration('mli')
      'ocaml-merlin:return-from-declaration': => @returnFromDeclaration()
      'ocaml-merlin:shrink-selection': => @shrinkSelection()
      'ocaml-merlin:expand-selection': => @expandSelection()
      'ocaml-merlin:rename-variable': => @renameVariable()
      'ocaml-merlin:restart-merlin': => @restartMerlin()

    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      @subscriptions.add editor.observeGrammar (grammar) =>
        if ['source.ocaml', 'source.ocamllex', 'source.ocamlyacc'].includes grammar.scopeName
          @addBuffer editor.getBuffer()
        else
          @removeBuffer editor.getBuffer()
      @subscriptions.add editor.onDidDestroy =>
        delete @typeViews[editor.id]
        delete @selectionViews[editor.id]

  restartMerlin: ->
    buffer.setChanged true for _, buffer of @buffers
    @merlin.restart()

  addBuffer: (textBuffer) ->
    bufferId = textBuffer.getId()
    return if @buffers[bufferId]?
    buffer = new Buffer textBuffer, => delete @buffers[bufferId]
    @buffers[bufferId] = buffer
    @merlin.project buffer
    .then ({merlinFiles, failures}) =>
      atom.workspace.notificationManager.addError failures.join '\n' if failures?
      return if merlinFiles.length
      @merlin.setFlags buffer, atom.config.get 'ocaml-merlin.default.flags'
      .then ({failures}) ->
        atom.workspace.notificationManager.addError failures.join '\n' if failures?
      @merlin.usePackages buffer, atom.config.get 'ocaml-merlin.default.packages'
      .then ({failures}) ->
        atom.workspace.notificationManager.addError failures.join '\n' if failures?
      @merlin.enableExtensions buffer, atom.config.get 'ocaml-merlin.default.extensions'
      @merlin.addSourcePaths buffer, atom.config.get 'ocaml-merlin.default.sourcePaths'
      @merlin.addBuildPaths buffer, atom.config.get 'ocaml-merlin.default.buildPaths'

  removeBuffer: (textBuffer) ->
    @buffers[textBuffer.getId()]?.destroy()

  getBuffer: (editor) ->
    @buffers[editor.getBuffer().getId()]

  showType: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    @typeViews[editor.id]?.destroy()
    @merlin.type @getBuffer(editor), editor.getCursorBufferPosition()
    .then (typeList) =>
      return unless typeList.length
      typeView = new TypeView typeList, editor
      @latestType = typeView.show()
      @typeViews[editor.id] = typeView

  shrinkType: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    @latestType = @typeViews[editor.id]?.shrink()

  expandType: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    @latestType = @typeViews[editor.id]?.expand()

  closeType: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    @typeViews[editor.id]?.destroy()
    delete @typeViews[editor.id]

  insertType: ->
    return unless @latestType?
    return unless editor = atom.workspace.getActiveTextEditor()
    editor.insertText @latestType

  destruct: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    @merlin.destruct @getBuffer(editor), editor.getSelectedBufferRange()
    .then ({range, content}) =>
      editor.transact 100, =>
        range = editor.setTextInBufferRange range, content
        @indentRange editor, range if @indentRange?
    , ({message}) ->
      atom.workspace.notificationManager.addError message

  getOccurrence: (offset) ->
    return unless editor = atom.workspace.getActiveTextEditor()
    point = editor.getCursorBufferPosition()
    @merlin.occurrences @getBuffer(editor), point
    .then (ranges) ->
      index = ranges.findIndex (range) -> range.containsPoint point
      range = ranges[(index + offset) % ranges.length]
      editor.setSelectedBufferRange range

  goToDeclaration: (kind) ->
    return unless editor = atom.workspace.getActiveTextEditor()
    currentPoint = editor.getCursorBufferPosition()
    @merlin.locate @getBuffer(editor), currentPoint, kind
    .then ({file, point}) =>
      @positions.push
        file: editor.getPath()
        point: currentPoint
      if file?
        atom.workspace.open file,
          initialLine: point.row
          initialColumn: point.column
          pending: true
          searchAllPanes: true
      else
        editor.setCursorBufferPosition point
    , (reason) ->
      atom.workspace.notificationManager.addError reason

  returnFromDeclaration: ->
    return unless position = @positions.pop()
    atom.workspace.open position.file,
      initialLine: position.point.row
      initialColumn: position.point.column
      pending: true
      searchAllPanes: true

  getSelectionView: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    selectionView = @selectionViews[editor.id]
    return Promise.resolve(selectionView) if selectionView?.isAlive()
    @merlin.enclosing @getBuffer(editor), editor.getCursorBufferPosition()
    .then (ranges) =>
      selectionView = new SelectionView editor, ranges
      @selectionViews[editor.id] = selectionView

  shrinkSelection: ->
    @getSelectionView().then (selectionView) -> selectionView.shrink()

  expandSelection: ->
    @getSelectionView().then (selectionView) -> selectionView.expand()

  renameView: (name, callback) ->
    RenameView ?= require './rename-view'
    new RenameView {name, callback}

  renameVariable: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    @merlin.occurrences @getBuffer(editor), editor.getCursorBufferPosition()
    .then (ranges) =>
      currentName = editor.getTextInBufferRange ranges[0]
      @renameView currentName, (newName) ->
        editor.transact ->
          ranges.reverse().map (range) ->
            editor.setTextInBufferRange range, newName

  deactivate: ->
    @merlin.close()
    @subscriptions.dispose()
    buffer.destroy() for _, buffer of @buffers

  getPrefix: (editor, point) ->
    line = editor.getTextInBufferRange([[point.row, 0], point])
    line.match(/[^\s\[\](){}<>,+*\/-]*$/)[0]

  provideAutocomplete: ->
    minimumWordLength = 1
    @subscriptions.add atom.config.observe "autocomplete-plus.minimumWordLength", (value) ->
      minimumWordLength = value
    completePartialPrefixes = false
    @subscriptions.add atom.config.observe "ocaml-merlin.completePartialPrefixes", (value) ->
      completePartialPrefixes = value
    kindToType =
      "Value": "value"
      "Variant": "variable"
      "Constructor": "class"
      "Label": "keyword"
      "Module": "method"
      "Signature": "type"
      "Type": "type"
      "Method": "property"
      "#": "constant"
      "Exn": "keyword"
      "Class": "class"
    selector: '.source.ocaml, .source.ocamllex, .source.ocamlyacc'
    getSuggestions: ({editor, bufferPosition, activatedManually}) =>
      prefix = @getPrefix editor, bufferPosition
      return [] if prefix.length < (if activatedManually then 1 else minimumWordLength)
      if completePartialPrefixes
        replacement = prefix
        promise = @merlin.expand @getBuffer(editor), bufferPosition, prefix
      else
        index = prefix.lastIndexOf "."
        replacement = prefix.substr(index + 1) if index >= 0
        promise = @merlin.complete @getBuffer(editor), bufferPosition, prefix
      promise.then (entries) ->
        entries.map ({name, kind, desc, info}) ->
          text: name
          replacementPrefix: replacement
          type: kindToType[kind]
          leftLabel: kind
          rightLabel: desc
          description: if info.length then info else desc
    inclusionPriority: 1

  provideLinter: ->
    name: 'OCaml Merlin'
    grammarScopes: ['source.ocaml']
    scope: 'file'
    lintOnFly: atom.config.get 'ocaml-merlin.lintAsYouType'
    lint: (editor) =>
      @merlin.errors @getBuffer(editor)
      .then (errors) ->
        errors.map ({range, type, message}) ->
          severity = if type is 'warning' then 'warning' else 'error'
          type: type[0].toUpperCase() + type[1..-1]
          class: severity
          text: message[0].toUpperCase() + message[1..-1]
          filePath: editor.getPath()
          range: range
          severity: severity

  consumeIndent: ({@indentRange}) ->
    Disposable => @indentRange = null
