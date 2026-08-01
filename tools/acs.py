#!/usr/bin/env python3
"""Minimal TR-069 CWMP ACS for enumerating/setting CPE parameters.

Protocol flow (TR-069):
  CPE POST Inform            -> we reply InformResponse
  CPE POST <RpcResponse>     -> we log it, reply 204
  CPE POST (empty body)      -> if /tmp/acs_next.txt exists, consume it and
                                reply with that RPC request; else reply 204

acs_next.txt format:
  line 1: CWMP method, e.g.  cwmp:GetParameterNames
  rest  : inner XML of the method body
"""
import http.server, socketserver, os, re, time, sys, threading

LOGDIR = '/tmp/acs_log'
CMDFILE = '/tmp/acs_next.txt'
LISTEN = ('0.0.0.0', 7547)
os.makedirs(LOGDIR, exist_ok=True)

CWMP_NS = 'urn:dslforum-org:cwmp-1-0'
state = {'ns': CWMP_NS, 'req_id': 1000}
loglock = threading.Lock()

def log(name, data):
    with loglock:
        ts = time.strftime('%H%M%S')
        path = os.path.join(LOGDIR, f'{ts}_{name}.xml')
        with open(path, 'w', errors='replace') as f:
            f.write(data if isinstance(data, str) else data.decode('utf-8', 'replace'))
        print(f'[acs] logged {path} ({len(data)} bytes)', flush=True)

def envelope(body_inner, method=None):
    ns = state['ns']
    hdr = ''
    if method:
        state['req_id'] += 1
        hdr = (f'<soap-env:Header><cwmp:ID soap-env:mustUnderstand="1">'
               f'{state["req_id"]}</cwmp:ID></soap-env:Header>')
    return (f'<?xml version="1.0" encoding="UTF-8"?>'
            f'<soap-env:Envelope xmlns:soap-env="http://schemas.xmlsoap.org/soap/envelope/" '
            f'xmlns:soap-enc="http://schemas.xmlsoap.org/soap/encoding/" '
            f'xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
            f'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            f'xmlns:cwmp="{ns}">{hdr}<soap-env:Body>{body_inner}</soap-env:Body></soap-env:Envelope>')

def inform_response():
    return envelope('<cwmp:InformResponse><MaxEnvelopes>1</MaxEnvelopes></cwmp:InformResponse>')

def transfer_complete_response():
    return envelope('<cwmp:TransferCompleteResponse></cwmp:TransferCompleteResponse>')

def next_rpc():
    """Consume cmd file, build an ACS request, or return None."""
    try:
        with open(CMDFILE) as f:
            content = f.read()
        os.rename(CMDFILE, CMDFILE + '.sent')
    except OSError:
        return None
    lines = content.strip().split('\n', 1)
    method = lines[0].strip()
    inner = lines[1].strip() if len(lines) > 1 else ''
    body = f'<{method}>{inner}</{method}>'
    return method, envelope(body, method=method)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        print('[http]', fmt % args, flush=True)

    def _send(self, code, body=b'', ctype='text/xml; charset=utf-8', soap_action=None):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        if body:
            self.send_header('Content-Type', ctype)
        if soap_action:
            self.send_header('SOAPAction', soap_action)
        self.send_header('Connection', 'keep-alive')
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        self._send(200, b'ACS up\n', 'text/plain')

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else b''
        text = body.decode('utf-8', 'replace')

        # remember the device's cwmp namespace
        m = re.search(r'xmlns:cwmp="([^"]+)"', text)
        if m:
            state['ns'] = m.group(1)

        if not body:
            rpc = next_rpc()
            if rpc:
                method, xml = rpc
                print(f'[acs] -> sending {method}', flush=True)
                log('REQ_' + method.replace(':', '_'), xml)
                self._send(200, xml.encode(), soap_action=method)
            else:
                self._send(204)
            return

        if '<cwmp:Inform>' in text or ':Inform>' in text and 'InformResponse' not in text:
            log('Inform', text)
            self._send(200, inform_response().encode())
            # auto-enable SSH: queue SPV if no manual command pending
            if os.path.exists('/tmp/acs_autossh') and not os.path.exists(CMDFILE):
                with open(CMDFILE, 'w') as f:
                    f.write('cwmp:SetParameterValues\n'
                            '<ParameterList SOAP-ENC:arrayType="cwmp:ParameterValueStruct[1]">'
                            '<ParameterValueStruct><Name>Device.X_ARC_COM.SSHEnable</Name>'
                            '<Value xsi:type="xsd:boolean">1</Value></ParameterValueStruct>'
                            '</ParameterList><ParameterKey>auto-ssh</ParameterKey>')
                print('[acs] auto-queued SSHEnable=1', flush=True)
        elif 'TransferComplete' in text and 'Response' not in text:
            log('TransferComplete', text)
            self._send(200, transfer_complete_response().encode())
        else:
            # RPC response or Fault from CPE
            name = 'RESP'
            m = re.search(r'<cwmp:(\w+Response)>', text)
            if m:
                name = 'RESP_' + m.group(1)
            elif '<SOAP-ENV:Fault>' in text or '<soap-env:Fault>' in text or 'Fault' in text:
                name = 'FAULT'
            log(name, text)
            self._send(204)

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == '__main__':
    srv = Server(LISTEN, Handler)
    print(f'[acs] listening on {LISTEN[0]}:{LISTEN[1]}', flush=True)
    srv.serve_forever()
