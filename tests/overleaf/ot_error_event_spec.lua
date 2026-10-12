local bridge = require('overleaf.bridge')
local ol = require('overleaf')

-- Overleaf sends otUpdateError to every client in the project and then boots
-- them all (P5). Only a document with an op in flight can have caused it.
describe('otUpdateError event', function()
  local saved = {}
  local handlers

  before_each(function()
    saved.on_event, saved.handlers, saved.state = bridge.on_event, bridge._event_handlers, ol._state
    handlers = {}
    bridge._event_handlers = {}
    bridge.on_event = function(name, handler)
      handlers[name] = handler
      bridge._event_handlers[name] = { handler }
    end
    ol._registered_handlers = nil
  end)

  after_each(function()
    bridge.on_event, bridge._event_handlers, ol._state = saved.on_event, saved.handlers, saved.state
    ol._registered_handlers = nil
  end)

  local function fake(inflight)
    local d = { inflight_op = inflight, rejoins = 0 }
    function d:rejoin() self.rejoins = self.rejoins + 1 end
    return d
  end

  it('rejoins only the named document, and only with an op in flight', function()
    local busy, idle, other = fake({ { p = 0, i = 'x' } }), fake(nil), fake({ { p = 0, i = 'y' } })
    ol._state = { connected = true, documents = { busy = busy, idle = idle, other = other } }
    ol._setup_event_handlers()
    handlers.otUpdateError({ message = 'Delete component does not match', doc_id = 'busy' })
    handlers.otUpdateError({ message = 'Delete component does not match', doc_id = 'idle' })
    handlers.otUpdateError({ message = 'no doc id' })
    assert.are.equal(1, busy.rejoins)
    assert.are.equal(0, idle.rejoins)
    assert.are.equal(0, other.rejoins)
    assert.is_true(busy._inflight_rejected)
    assert.is_nil(idle._inflight_rejected)
  end)
end)
