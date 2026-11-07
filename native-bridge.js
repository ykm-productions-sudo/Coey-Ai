/*
 * Coey Ai — iOS native bridge
 *
 * The web bundle calls into four globals that the Android build used:
 *   window.__coeyEngine       Wllama-compatible local llama.cpp engine
 *   window.__coeyElevenVoice  ElevenLabs voice lookup
 *   window.__coeyEleven       ElevenLabs text-to-speech playback
 *   window.__coeyElevenStop   stop the current spoken line
 *
 * This file implements them on top of WKScriptMessageHandler("coey").
 * It runs before the React module, so the bundle never falls back to
 * the WebAssembly build.
 */
(function () {
  'use strict';

  var host =
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.coey;
  if (!host) return; // running in a plain browser: keep the web fallback

  var seq = 1;
  var pending = Object.create(null);

  window.__coeyPlatform = 'ios';

  function post(cmd, payload, events) {
    var id = seq++;
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject, events: events || {} };
      var msg = { id: id, cmd: cmd };
      if (payload) {
        for (var k in payload) {
          if (Object.prototype.hasOwnProperty.call(payload, k)) msg[k] = payload[k];
        }
      }
      host.postMessage(msg);
    });
  }

  window.__coeyNative = function (msg) {
    if (!msg || msg.id == null) return;
    var p = pending[msg.id];
    if (!p) return;
    switch (msg.type) {
      case 'progress':
        if (p.events.progress) p.events.progress(msg);
        break;
      case 'token':
        if (p.events.token) p.events.token(msg);
        break;
      case 'event':
        if (p.events.event) p.events.event(msg);
        break;
      case 'done':
        delete pending[msg.id];
        p.resolve(msg);
        break;
      case 'error':
        delete pending[msg.id];
        p.reject(new Error(msg.message || 'The native side failed.'));
        break;
      default:
        break;
    }
  };

  /* ------------------------------------------------------------------ */
  /* Local llama.cpp engine                                              */
  /* ------------------------------------------------------------------ */

  var modelLoaded = false;

  function hfURL(model) {
    if (!model) throw new Error('Missing model descriptor.');
    if (model.url) return model.url;
    if (!model.repo || !model.file) throw new Error('Missing model repo or file.');
    return (
      'https://huggingface.co/' +
      model.repo +
      '/resolve/main/' +
      encodeURIComponent(model.file)
    );
  }

  function threadCount() {
    var n = navigator.hardwareConcurrency || 2;
    return Math.max(1, Math.min(4, n));
  }

  function NativeEngine() {
    this.metadata = {
      meta: { 'general.name': 'Qwen2.5-0.5B-Instruct-abliterated' }
    };
  }

  NativeEngine.prototype.loadModelFromHF = function (model, opts) {
    opts = opts || {};
    var self = this;
    var file = (model && model.file) || '';
    var expected =
      file.indexOf('Qwen2.5-0.5B-Instruct-abliterated') >= 0 ? 397808512 : 0;

    return post(
      'model.load',
      {
        url: hfURL(model),
        file: file,
        expectedBytes: expected,
        nCtx: opts.n_ctx || 2048,
        nThreads: opts.n_threads || threadCount(),
        nBatch: opts.n_batch || 128
      },
      {
        progress: function (m) {
          if (opts.progressCallback) {
            opts.progressCallback({ loaded: m.loaded || 0, total: m.total || 0 });
          }
        }
      }
    ).then(function () {
      modelLoaded = true;
      return { success: true };
    });
  };

  NativeEngine.prototype.loadModelFromUrl = function (model, opts) {
    return this.loadModelFromHF(model, opts);
  };

  NativeEngine.prototype.isModelLoaded = function () {
    return !!modelLoaded;
  };
  NativeEngine.prototype.isMultithread = function () {
    return true;
  };
  NativeEngine.prototype.getNumThreads = function () {
    return threadCount();
  };
  NativeEngine.prototype.mustAddBosToken = function () {
    return false;
  };
  NativeEngine.prototype.mustAddEosToken = function () {
    return false;
  };
  NativeEngine.prototype.getChatTemplate = function () {
    return null;
  };
  NativeEngine.prototype.getModelMetadata = function () {
    return this.metadata;
  };
  NativeEngine.prototype.isEncoderDecoderArchitecture = function () {
    return false;
  };

  NativeEngine.prototype.createChatCompletion = function (opts) {
    opts = opts || {};
    var ref = 'chat-' + seq;
    var onAbort = null;

    if (opts.abortSignal && opts.abortSignal.aborted) {
      return Promise.resolve({ choices: [] });
    }

    var payload = {
      ref: ref,
      messages: (opts.messages || []).map(function (m) {
        return { role: String(m.role || 'user'), content: String(m.content || '') };
      }),
      temperature: opts.temperature == null ? 0.8 : opts.temperature,
      topP: opts.top_p == null ? 0.95 : opts.top_p,
      topK: opts.top_k == null ? 40 : opts.top_k,
      repeatPenalty: opts.penalty_repeat == null ? 1.1 : opts.penalty_repeat,
      maxTokens: opts.max_tokens == null ? 256 : opts.max_tokens
    };

    if (opts.abortSignal) {
      onAbort = function () {
        post('chat.abort', { ref: ref }).catch(function () {});
      };
      opts.abortSignal.addEventListener('abort', onAbort, { once: true });
    }

    function cleanup() {
      if (onAbort && opts.abortSignal) {
        opts.abortSignal.removeEventListener('abort', onAbort);
      }
    }

    return post('chat.start', payload, {
      token: function (m) {
        if (m.token && opts.onData) {
          opts.onData({
            choices: [{ index: 0, delta: { content: m.token } }]
          });
        }
      }
    }).then(
      function (res) {
        cleanup();
        if (!opts.stream || opts.onData) return res;
        return {
          choices: [{ index: 0, message: { role: 'assistant', content: res.text || '' } }]
        };
      },
      function (err) {
        cleanup();
        throw err;
      }
    );
  };

  NativeEngine.prototype.createCompletion = function (opts) {
    var opts2 = opts || {};
    var prompt = typeof opts2.prompt === 'string' ? opts2.prompt : '';
    return this.createChatCompletion({
      messages: [{ role: 'user', content: prompt }],
      temperature: opts2.temperature,
      top_p: opts2.top_p,
      top_k: opts2.top_k,
      penalty_repeat: opts2.penalty_repeat,
      max_tokens: opts2.nPredict || opts2.max_tokens || 256,
      stream: opts2.stream,
      onData: opts2.onData ? function (d) { opts2.onData(d); } : undefined,
      abortSignal: opts2.abortSignal
    });
  };

  NativeEngine.prototype.abort = function () {
    post('chat.abort', { ref: '' }).catch(function () {});
  };

  NativeEngine.prototype.exit = function () {
    modelLoaded = false;
    return post('model.unload', {}).catch(function () {});
  };

  window.__coeyEngine = new NativeEngine();

  /* ------------------------------------------------------------------ */
  /* Speech recognition (WKWebView has no webkitSpeechRecognition)        */
  /* ------------------------------------------------------------------ */

  var speechSessions = Object.create(null);

  function NativeSpeechRecognition() {
    this.lang = navigator.language || 'en-US';
    this.continuous = true;
    this.interimResults = true;
    this.onresult = null;
    this.onend = null;
    this.onerror = null;
    this._session = 0;
  }

  NativeSpeechRecognition.prototype._cleanup = function (sessionId) {
    if (this._session === sessionId) this._session = 0;
    delete pending[sessionId];
    delete speechSessions[sessionId];
  };

  NativeSpeechRecognition.prototype.start = function () {
    if (this._session) return;
    var self = this;
    var id = ++seq;
    this._session = id;
    speechSessions[id] = this;

    pending[id] = {
      resolve: function () {},
      reject: function () {},
      events: {
        event: function (m) {
          if (m.name === 'speech') {
            var result = [{ transcript: m.transcript || '' }];
            result.isFinal = !!m.final;
            result.length = 1;
            if (self.onresult) {
              self.onresult({ results: [result], resultIndex: 0 });
            }
          } else if (m.name === 'speechEnd') {
            self._cleanup(id);
            if (self.onend) self.onend();
          } else if (m.name === 'speechError') {
            self._cleanup(id);
            if (self.onerror) {
              self.onerror({ error: 'native', message: m.message });
            }
          }
        }
      }
    };

    host.postMessage({ id: id, cmd: 'speech.start', lang: this.lang });
  };

  NativeSpeechRecognition.prototype.stop = function () {
    var id = this._session;
    if (!id) return;
    host.postMessage({ id: id, cmd: 'speech.stop' });
    this._cleanup(id);
  };

  NativeSpeechRecognition.prototype.abort = function () {
    this.stop();
  };

  if (!window.webkitSpeechRecognition) {
    window.webkitSpeechRecognition = NativeSpeechRecognition;
    window.SpeechRecognition = NativeSpeechRecognition;
  }

  /* ------------------------------------------------------------------ */
  /* ElevenLabs voice                                                    */
  /* ------------------------------------------------------------------ */

  var voiceToken = 0;
  var voiceRaf = 0;
  var voiceStart = 0;

  window.__coeyElevenStop = function () {
    voiceToken++;
    if (voiceRaf) cancelAnimationFrame(voiceRaf);
    voiceRaf = 0;
    post('voice.stop', {}).catch(function () {});
  };

  window.__coeyElevenVoice = function (apiKey, voiceId) {
    return post('voice.name', { apiKey: apiKey, voiceId: voiceId }).then(function (r) {
      return (r && r.name) || 'ElevenLabs';
    });
  };

  window.__coeyEleven = function (o) {
    o = o || {};
    var my = ++voiceToken;
    var started = false;

    function begin() {
      if (started) return;
      started = true;
      if (o.onStart) o.onStart();
      voiceStart = performance.now();
      animate();
    }

    function finish() {
      if (my !== voiceToken) return;
      if (voiceRaf) cancelAnimationFrame(voiceRaf);
      voiceRaf = 0;
      if (o.alive && !o.alive()) return;
      if (o.onEnd) o.onEnd();
    }

    function animate() {
      if (my !== voiceToken) return;
      if (o.alive && !o.alive()) {
        finish();
        return;
      }
      var t = (performance.now() - voiceStart) / 1000;
      var v = 0.34 + 0.22 * Math.sin(t * 11.3) * Math.sin(t * 4.1 + 0.6);
      if (o.onMouth) o.onMouth(Math.min(0.95, Math.max(0.12, v)));
      voiceRaf = requestAnimationFrame(animate);
    }

    post(
      'voice.speak',
      { apiKey: o.key, voiceId: o.voiceId, text: o.text },
      {
        event: function (m) {
          if (m.name === 'ended') finish();
        }
      }
    )
      .then(function () {
        if (my !== voiceToken) return;
        if (o.alive && !o.alive()) {
          finish();
          return;
        }
        begin();
      })
      .catch(function (err) {
        if (my !== voiceToken) return;
        if (window.console && console.warn) console.warn('[coey] voice:', err);
        finish();
      });

    return Promise.resolve();
  };
})();
