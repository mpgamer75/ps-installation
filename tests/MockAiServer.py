"""Faux service d'IA pour les tests : imite l'API Messages d'Anthropic et l'API
chat/completions compatible OpenAI (flux SSE, jetons, erreurs, liste de modèles).

    python3 tests/MockAiServer.py <port> <fichier-de-trace> [secondes]
"""
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, TRACE = int(sys.argv[1]), sys.argv[2]
LIFETIME = float(sys.argv[3]) if len(sys.argv) > 3 else 120


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def key(self):
        auth = self.headers.get('Authorization', '')
        return self.headers.get('x-api-key') or (auth[7:] if auth.startswith('Bearer ') else '')

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.key() == 'bad':
            return self.send_json(401, {'error': {'message': 'invalid api key'}})
        if self.path.startswith('/v1/models') and self.headers.get('x-api-key'):
            return self.send_json(200, {'data': [{'id': 'claude-opus-5-5'}, {'id': 'claude-sonnet-5-5'}]})
        if self.path.endswith('/models'):
            return self.send_json(200, {'data': [
                {'id': 'gpt-6.2-sol'}, {'id': 'text-embedding-9'}, {'id': 'mon-modele-maison'},
                {'id': 'vendor/priced-model', 'pricing': {'prompt': '0.000002', 'completion': '0.000008'}}]})
        self.send_json(404, {'error': {'message': 'not found'}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(TRACE, 'w', encoding='utf-8') as f:
            json.dump({'path': self.path, 'headers': {k.lower(): v for k, v in self.headers.items()}, 'body': body}, f, ensure_ascii=False)
        key = self.key()
        if key == 'bad':
            return self.send_json(401, {'error': {'type': 'authentication_error', 'message': 'invalid api key'}})
        if key == 'nostreamoptions' and 'stream_options' in body:
            return self.send_json(400, {'error': {'message': 'Unrecognized request argument: stream_options'}})
        system = body.get('system') or next((m['content'] for m in body.get('messages', []) if m['role'] == 'system'), '')
        parts = ['Get-ChildItem ', '-File'] if 'seule ligne' in system else ['Bonjour, ', 'réponse accentuée : éàü.']
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()

        def send(data, event=None):
            prefix = f'event: {event}\n' if event else ''
            self.wfile.write(f'{prefix}data: {json.dumps(data, ensure_ascii=False)}\n\n'.encode())
            self.wfile.flush()

        if self.path.endswith('/v1/messages'):
            send({'type': 'message_start', 'message': {'id': 'msg_1', 'model': body['model'], 'usage': {'input_tokens': 1200, 'output_tokens': 1}}}, 'message_start')
            send({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}, 'content_block_start')
            for p in parts:
                send({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': p}}, 'content_block_delta')
            stop = 'refusal' if key == 'refuse' else 'end_turn'
            send({'type': 'message_delta', 'delta': {'stop_reason': stop}, 'usage': {'output_tokens': 300}}, 'message_delta')
            send({'type': 'message_stop'}, 'message_stop')
        else:
            for p in parts:
                send({'model': body['model'], 'choices': [{'index': 0, 'delta': {'content': p}, 'finish_reason': None}]})
            send({'model': body['model'], 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})
            usage = {'prompt_tokens': 2000, 'completion_tokens': 500}
            if key == 'withcost':
                usage['cost'] = 0.0421
            if key == 'groq':
                send({'model': body['model'], 'choices': [], 'x_groq': {'usage': usage}})
            elif key != 'nousage' and 'stream_options' in body or key in ('withcost', 'nostreamoptions'):
                send({'model': body['model'], 'choices': [], 'usage': usage})
            self.wfile.write(b'data: [DONE]\n\n')


server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
threading.Timer(LIFETIME, server.shutdown).start()
server.serve_forever()
