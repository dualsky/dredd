{assert} = require 'chai'
sinon = require 'sinon'
express = require 'express'

proxyquire = require('proxyquire').noCallThru()

packageJson = require '../../package.json'
loggerStub = require '../../src/logger'
options = require '../../src/options'

PORT = 9876

exitStatus = null

stderr = ''
stdout = ''

addHooksStub = proxyquire '../../src/add-hooks', {
  './logger': loggerStub
}
transactionRunner = proxyquire '../../src/transaction-runner', {
  './add-hooks': addHooksStub
  './logger': loggerStub
}
dreddStub = proxyquire '../../src/dredd', {
  './transaction-runner': transactionRunner
  './logger': loggerStub
}
DreddCommand = proxyquire '../../src/command', {
  './dredd': dreddStub
  'console': loggerStub
}

execCommand = (custom = {}, cb) ->
  stdout = ''
  stderr = ''
  exitStatus = null
  finished = false
  dreddCommand = new DreddCommand({
    custom: custom
  }, (code) ->
    if not finished
      finished = true
      exitStatus = (code ? 0)
      cb null, stdout, stderr, (code ? 0)
  ).warmUp().takeoff()
  return

describe "DreddCommand class", () ->
  dreddCommand = null
  env = {}

  before ->
    for method in ['warn', 'error'] then do (method) ->
      sinon.stub loggerStub, method, (chunk) -> stderr += "\n#{method}: #{chunk}"
    for method in ['log', 'info', 'silly', 'verbose', 'test', 'diff', 'complete', 'pass', 'skip', 'debug', 'fail', 'request', 'expected', 'actual'] then do (method) ->
      sinon.stub loggerStub, method, (chunk) -> stdout += "\n#{method}: #{chunk}"
    return

  after ->
    for method in ['warn', 'error']
      loggerStub[method].restore()
    for method in ['log', 'info', 'silly', 'verbose', 'test', 'diff', 'complete', 'pass', 'skip', 'debug', 'fail', 'request', 'expected', 'actual']
      loggerStub[method].restore()
    return


  describe 'when initialized without "new" keyword', ->
    dc = null
    before ->
      dc = DreddCommand()

    it 'sets finished to false', ->
      assert.isFalse dc.finished

    it 'sets custom to an Object with "argv" and "cwd" keys', ->
      assert.isObject dc.custom
      assert.lengthOf Object.keys(dc.custom), 2
      assert.property dc.custom, 'cwd'
      assert.property dc.custom, 'argv'

    it 'sets custom argv to an Array with process.argv', ->
      assert.isArray dc.custom?.argv
      assert.equal dc.custom?.argv.length, 0

    it 'returns an instanceof DreddCommand', ->
      assert.instanceOf dc, DreddCommand


  describe 'when initialized with options containing exit callback', ->
    dc = null
    hasCalledExit = null

    before () ->
      dc = DreddCommand({exit: (code) ->
        hasCalledExit = true
      })
      dc.warmUp()?.takeoff?()

    it 'has argv property set to object with properties from optimist', ->
      assert.isObject dc.argv
      assert.property dc.argv, '_'
      assert.isArray dc.argv['_']

    it 'does not set finished to true (keeps false)', ->
      assert.isFalse dc.finished

    it 'ends with an error message about missing blueprint-file', ->
      assert.include stderr, 'Must specify path to blueprint file.'

    it 'ends with an error message about missing api endpoint.', ->
      assert.include stderr, 'Must specify api endpoint.'

    it 'calls exit callback', ->
      assert.isNotNull hasCalledExit


  describe 'warmUp', ->
    dc = null
    initDreddStub = null
    initConfigSpy = null
    lastArgvIsApiEndpointSpy = null
    takeRestOfParamsAsPathSpy = null

    before ->
      dc = new DreddCommand({
        exit: ->
        custom:
          argv: ['./file.apib', 'http://localhost:3000']
          env: {'NO_KEY': 'NO_VAL'}
      })
      initDreddStub = sinon.stub dc, 'initDredd', ->
        return 'myDreddInstance'
      initConfigSpy = sinon.spy dc, 'initConfig'
      lastArgvIsApiEndpointSpy = sinon.spy dc, 'lastArgvIsApiEndpoint'
      takeRestOfParamsAsPathSpy = sinon.spy dc, 'takeRestOfParamsAsPath'

    after ->
      dc.initDredd.restore()
      dc.initConfig.restore()
      dc.lastArgvIsApiEndpoint.restore()
      dc.takeRestOfParamsAsPath.restore()

    describe 'with mocked initDredd', ->
      before ->
        dc.warmUp()

      it 'should call initConfig', ->
        assert.equal initConfigSpy.called, 1

      it 'should call susequent helpers as part of initConfig', ->
        assert.equal lastArgvIsApiEndpointSpy.called, 1
        assert.equal takeRestOfParamsAsPathSpy.called, 1

      it 'should call initDredd with configuration object', ->
        assert.equal dc.initDredd.called, 1
        assert.isArray dc.initDredd.firstCall.args
        assert.lengthOf dc.initDredd.firstCall.args, 1
        assert.property dc.initDredd.firstCall.args[0], 'server'
        assert.property dc.initDredd.firstCall.args[0], 'options'
        assert.property dc.initDredd.firstCall.args[0], 'custom'
        assert.equal dc.dreddInstance, 'myDreddInstance'


  describe 'takeoff without argv set', ->
    dc = null
    runDreddStub = null
    exitCalled = null
    beforeEach ->
      dc = new DreddCommand({
        exit: ->
          exitCalled = true
      })
      dc.dreddInstance = 'dreddInstance'
      runDreddStub = sinon.stub dc, 'runDredd', ->

    afterEach ->
      dc.runDredd.restore()

    describe 'with finished set to false', ->
      it 'should not call exit callback', ->
        assert.isNull exitCalled
      it 'does call runDredd just once with dreddInstance as first argument', ->
        runDreddStub.reset()
        dc.takeoff()
        assert.equal dc.runDredd.called, 1
        assert.isArray dc.runDredd.firstCall.args
        assert.lengthOf dc.runDredd.firstCall.args, 1
        assert.deepEqual dc.runDredd.firstCall.args, ['dreddInstance']

    describe 'with finished set to true', ->
      it 'does not call runDredd at all', ->
        runDreddStub.reset()
        dc.finished = true
        dc.takeoff()
        assert.equal dc.runDredd.called, 0


  describe 'takeoff with argv set to load regular blueprint', ->
    dc = null
    runDreddStub = null
    returnGood = true

    beforeEach (done) ->
      app = express()

      app.get '/machines', (req, res) ->
        if returnGood
          res.type('json').status(200).send [type: 'bulldozer', name: 'willy']
        else
          res.type('json').status(200).send [my: 'another', world: 'service']

      dc = new DreddCommand({
        custom:
          argv: [
            './test/fixtures/single-get.apib'
            "http://localhost:#{PORT}"
            '--path=./test/fixtures/single-get.apib'
          ]
        exit: (code) ->
          exitStatus = code
          server.close()
      })
      dc.warmUp()

      server = app.listen PORT, () ->
        dc.takeoff()

      server.on 'close', done

    describe 'with server returning good things', ->
      before ->
        returnGood = true

      it 'returns exit code 0', ->
        assert.equal exitStatus, 0

      it 'propagates configuration options to Dredd class', ->
        assert.equal dc.dreddInstance.configuration.options.path[0], "./test/fixtures/single-get.apib"
        assert.equal dc.dreddInstance.configuration.server, "http://localhost:#{PORT}"

    describe 'with server returning wrong things', ->

      before ->
        returnGood = false

      it 'returns exit code 1', ->
        assert.equal exitStatus, 1

      it 'propagates configuration options to Dredd class', ->
        assert.equal dc.dreddInstance.configuration.options.path[0], "./test/fixtures/single-get.apib"
        assert.equal dc.dreddInstance.configuration.server, "http://localhost:#{PORT}"


  describe "when called w/ OR wo/ special arguments", () ->
    describe '--help', ->
      before (done) ->
        execCommand argv: ['--help'], ->
          done()

      it 'prints out some really nice help text with all options descriptions', ->
        assert.include stderr, 'Usage:'
        assert.include stderr, 'Example:'
        assert.include stderr, '[OPTIONS]'
        for optionKey in Object.keys options then do (optionKey) ->
          assert.include stderr, optionKey

    describe '--version', ->
      before (done) ->
        execCommand argv: ['--version'], ->
          done()

      it 'prints out version', ->
        assert.include stdout, "#{packageJson.name} v#{packageJson.version}"

    describe 'without argv', ->
      before (done) ->
        execCommand argv: [], ->
          done()

      it 'prints out an error message', ->
        assert.include stderr, 'Error: Must specify'

