local merge = require('overleaf.merge')

describe('three-way text merge', function()
  it(
    'combines disjoint word changes',
    function() assert.are.equal('RED blue GREEN', merge.three_way('red blue green', 'RED blue green', 'red blue GREEN')) end
  )

  it(
    'rejects overlapping edits',
    function() assert.is_nil(merge.three_way('red blue green', 'red BLUE green', 'red black green')) end
  )

  it('rejects edits that touch at a boundary', function() assert.is_nil(merge.three_way('abcd', 'aXcd', 'abYd')) end)

  it(
    'treats separate edits inside one word as overlapping',
    function() assert.is_nil(merge.three_way('alphabet', 'alXphabet', 'alphabYt')) end
  )

  it(
    'takes identical edits once',
    function() assert.are.equal('red BLUE green', merge.three_way('red blue green', 'red BLUE green', 'red BLUE green')) end
  )

  it(
    'keeps astral characters intact',
    function() assert.are.equal('😀 red 𝔸', merge.three_way('😀 red blue', '😀 red 𝔸', '😀 red blue')) end
  )
end)
