# Plugin de yt-dlp de Setube para Android. Delega en el WebView de la app (Chromium/V8) dos cosas:
# - PO tokens de BotGuard, como el servicio bgutil de la API, para el cliente mweb (GVS).
# - Retos JS de YouTube (n/sig) con los scripts EJS de yt-dlp, mucho más rápido que QuickJS.
# La app escribe en helper.json (junto a esta carpeta) la URL del servidor local en 127.0.0.1.
# Si el servidor no responde, yt-dlp sigue con sus proveedores normales (QuickJS, sin PO token).

from __future__ import annotations

import json
import os

from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenContext,
    PoTokenProvider,
    PoTokenProviderError,
    PoTokenProviderRejectedRequest,
    PoTokenRequest,
    PoTokenResponse,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot.utils import WEBPO_CLIENTS, get_webpo_content_binding
from yt_dlp.networking.common import Request

__version__ = '1.0.0'
_BUGS = 'https://github.com/GarcesSebastian/setube-android/issues'


def _helper_url():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir, 'helper.json')
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f).get('url') or None
    except Exception:
        return None


def _post(provider, path, payload, timeout, note=None):
    url = _helper_url()
    if not url:
        return None
    if note:
        provider.logger.info(note)
    # Sin proxy: el servidor está en 127.0.0.1 dentro de la app
    response = provider.ie._downloader.urlopen(
        Request(f'{url}/{path}', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'},
                extensions={'timeout': timeout}, proxies={'all': None}))
    return json.load(response)


@register_provider
class SetubePTP(PoTokenProvider):
    PROVIDER_VERSION = __version__
    BUG_REPORT_LOCATION = _BUGS
    _SUPPORTED_CLIENTS = WEBPO_CLIENTS
    _SUPPORTED_CONTEXTS = (PoTokenContext.GVS, PoTokenContext.PLAYER, PoTokenContext.SUBS)
    _SUPPORTED_EXTERNAL_REQUEST_FEATURES = ()

    def is_available(self) -> bool:
        return _helper_url() is not None

    def _real_request_pot(self, request: PoTokenRequest) -> PoTokenResponse:
        binding = get_webpo_content_binding(request)[0]
        if not binding:
            raise PoTokenProviderRejectedRequest('No content binding for this request')
        try:
            data = _post(self, 'pot', {'binding': binding}, 30.0,
                         f'Generating a {request.context.value} PO Token for {request.internal_client_name} client via Setube WebView')
        except Exception as e:
            raise PoTokenProviderError(f'Setube WebView unavailable ({e!r})') from e
        if not data or not data.get('poToken'):
            raise PoTokenProviderError(f'Setube WebView did not return a PO Token: {(data or {}).get("error")}')
        return PoTokenResponse(po_token=data['poToken'])


@register_preference(SetubePTP)
def setube_pot_preference(provider, request):
    return 140


# Los retos JS usan una API interna de yt-dlp (EJSBaseJCP): si una versión futura la cambia, el plugin
# sigue cargando y yt-dlp vuelve a QuickJS.
try:
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    from yt_dlp.extractor.youtube.jsc.provider import (
        JsChallengeProvider,
        JsChallengeProviderError,
        JsChallengeRequest,
    )
    from yt_dlp.extractor.youtube.jsc.provider import register_preference as register_jcp_preference
    from yt_dlp.extractor.youtube.jsc.provider import register_provider as register_jcp
except ImportError:
    EJSBaseJCP = None

if EJSBaseJCP is not None:
    @register_jcp
    class SetubeWebViewJCP(EJSBaseJCP):
        PROVIDER_VERSION = __version__
        BUG_REPORT_LOCATION = _BUGS
        JS_RUNTIME_NAME = 'webview'
        # Guarda en --cache-dir el reproductor de YouTube ya preprocesado por los scripts EJS. yt-dlp lo trae
        # apagado (el archivo pesa ~4 MB), pero sin él cada proceso vuelve a analizar los 3 MB del reproductor:
        # con cientos de canciones es la mayor parte del tiempo de «preparando». La app borra los viejos.
        _ENABLE_PREPROCESSED_PLAYER_CACHE = True

        def is_available(self, /) -> bool:
            return self._available and _helper_url() is not None

        def _run_js_runtime(self, stdin: str, /) -> str:
            try:
                data = _post(self, 'js', {'script': stdin}, 60.0)
            except Exception as e:
                raise JsChallengeProviderError(f'Setube WebView unavailable ({e!r})') from e
            if not data or 'stdout' not in data:
                raise JsChallengeProviderError(f'Setube WebView failed: {(data or {}).get("error")}')
            return data['stdout']


    @register_jcp_preference(SetubeWebViewJCP)
    def setube_jcp_preference(provider: JsChallengeProvider, requests: list[JsChallengeRequest]) -> int:
        return 1000


__all__ = ['SetubePTP', 'setube_pot_preference']
if EJSBaseJCP is not None:
    __all__ += ['SetubeWebViewJCP', 'setube_jcp_preference']
