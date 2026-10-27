import json
import os
from datetime import datetime, timezone

from flask import Flask, jsonify, request
from flask_cors import CORS
import valkey

app = Flask(__name__)
CORS(app)

kv = valkey.Valkey(
    host=os.getenv('VALKEY_HOST', 'localhost'),
    port=6379,
    decode_responses=True,
)


@app.route('/api/notes', methods=['GET'])
def get_notes():
    raw = kv.lrange('notes', 0, -1)
    return jsonify([json.loads(n) for n in raw])


@app.route('/api/notes', methods=['POST'])
def add_note():
    data = request.get_json()
    note = {
        'author': data.get('author') or 'Anonymous',
        'text': data.get('text', '').strip(),
        'timestamp': datetime.now(timezone.utc).isoformat(),
    }
    kv.lpush('notes', json.dumps(note))
    return jsonify(note), 201


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
