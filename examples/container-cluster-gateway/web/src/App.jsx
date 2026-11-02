import { useState, useEffect } from 'react'

export default function App() {
  const [notes, setNotes] = useState([])
  const [author, setAuthor] = useState('')
  const [text, setText] = useState('')
  const [posting, setPosting] = useState(false)

  const fetchNotes = () =>
    fetch('/api/notes')
      .then(r => r.json())
      .then(setNotes)
      .catch(() => {})

  useEffect(() => {
    fetchNotes()
    const id = setInterval(fetchNotes, 3000)
    return () => clearInterval(id)
  }, [])

  const handleSubmit = async e => {
    e.preventDefault()
    if (!text.trim()) return
    setPosting(true)
    await fetch('/api/notes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ author: author.trim() || 'Anonymous', text: text.trim() }),
    })
    setText('')
    await fetchNotes()
    setPosting(false)
  }

  return (
    <div className="app">
      <header>
        <h1>Shared Notepad</h1>
        <p>React &middot; Flask &middot; Valkey</p>
      </header>

      <form onSubmit={handleSubmit}>
        <input
          placeholder="Your name (optional)"
          value={author}
          onChange={e => setAuthor(e.target.value)}
        />
        <textarea
          placeholder="Write a note..."
          value={text}
          onChange={e => setText(e.target.value)}
          required
        />
        <button type="submit" disabled={posting}>
          {posting ? 'Posting...' : 'Post Note'}
        </button>
      </form>

      <div className="notes">
        {notes.length === 0 ? (
          <p className="empty">No notes yet. Be the first to post.</p>
        ) : (
          notes.map((note, i) => (
            <div key={i} className="note">
              <div className="note-header">
                <strong>{note.author}</strong>
                <span>{new Date(note.timestamp).toLocaleTimeString()}</span>
              </div>
              <p>{note.text}</p>
            </div>
          ))
        )}
      </div>
    </div>
  )
}
