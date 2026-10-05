'use strict';

/*
 * Test-only preload (node --require ...): swaps https.get for a scripted fake, so the
 * wrapper's fetch and redirect handling can be exercised with no network and no TLS fixture.
 *
 *   FAKE_HTTPS_PLAN  JSON array, one step per request, consumed in order:
 *                      {"status": 302, "location": "/next"}      a redirect
 *                      {"status": 200, "body": "..."}            the payload
 *                      {"status": 404}                           an HTTP error
 *   FAKE_HTTPS_LOG   file the requested URLs are written to (one per line) when the process exits
 */

const fs = require('fs');
const https = require('https');
const { EventEmitter } = require('events');

const plan = JSON.parse(process.env.FAKE_HTTPS_PLAN || '[]');
const requested = [];

https.get = function (url, options, callback) {
  const step = plan[requested.length];
  requested.push(String(url));
  const req = new EventEmitter();
  req.setTimeout = function () { return req; };
  req.destroy = function (err) { req.emit('error', err); };
  process.nextTick(function () {
    if (!step) {
      req.emit('error', new Error('fake https: no scripted response for request #' + requested.length + ' (' + url + ')'));
      return;
    }
    const res = new EventEmitter();
    res.statusCode = step.status;
    res.headers = step.location ? { location: step.location } : {};
    res.resume = function () { res.resumed = true; };
    callback(res);
    if (typeof step.body === 'string') {
      res.emit('data', Buffer.from(step.body));
      res.emit('end');
    }
  });
  return req;
};

process.on('exit', function () {
  if (process.env.FAKE_HTTPS_LOG) {
    fs.writeFileSync(process.env.FAKE_HTTPS_LOG, requested.join('\n') + '\n');
  }
});
