package com.linkcode.app;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.res.AssetManager;
import android.net.Uri;
import android.os.Bundle;
import android.view.ViewGroup;
import android.webkit.MimeTypeMap;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Shows the LinkCode website inside a WebView.
 *
 * The website files (copied from the repository root at build time) are served from
 * the bundled assets under a virtual https origin, so the pages behave exactly like
 * they do on the web: relative links, /unlock, localStorage and Supabase calls all work.
 */
public class MainActivity extends Activity {

    /** Virtual https origin that serves the bundled website. */
    private static final String APP_HOST = "appassets.androidplatform.net";
    private static final String APP_BASE = "https://" + APP_HOST + "/";

    /** Public domain of the site. Links to it are opened inside the app. */
    private static final String SITE_HOST = "l2c.space";

    /** Six-digit short codes: /123456 becomes /unlock?code=123456 (same as the web routing). */
    private static final Pattern SHORT_CODE = Pattern.compile("^/(\\d{6})/?$");

    private WebView webView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        webView = new WebView(this);
        webView.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Keep the content clear of the status bar and navigation bar.
        // Android 15+ draws edge-to-edge, so the system bar area is padded here.
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFF071513);
        root.setFitsSystemWindows(true);
        root.addView(webView);
        setContentView(root);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setBuiltInZoomControls(false);
        settings.setSupportMultipleWindows(false);
        settings.setMediaPlaybackRequiresUserGesture(true);

        webView.setWebViewClient(new SiteWebViewClient());
        webView.setWebChromeClient(new WebChromeClient());

        boolean restored = savedInstanceState != null
                && webView.restoreState(savedInstanceState) != null;
        if (!restored) {
            String link = linkFromIntent(getIntent());
            webView.loadUrl(link != null ? link : APP_BASE);
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        String link = linkFromIntent(intent);
        if (link != null) {
            webView.loadUrl(link);
        }
    }

    @Override
    public void onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        webView.onResume();
    }

    @Override
    protected void onPause() {
        webView.onPause();
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        webView.saveState(outState);
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            webView.stopLoading();
            webView.destroy();
        }
        super.onDestroy();
    }

    /** Returns the bundled-site URL for an https://l2c.space link, or null if the intent is not one. */
    private static String linkFromIntent(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction())) {
            return null;
        }
        Uri data = intent.getData();
        if (data == null || !"https".equalsIgnoreCase(data.getScheme())
                || !SITE_HOST.equalsIgnoreCase(data.getHost())) {
            return null;
        }
        return toLocalUrl(data);
    }

    /** Maps a site URL such as https://l2c.space/Profile.html?u=bob to the bundled copy. */
    private static String toLocalUrl(Uri uri) {
        String path = pathOf(uri);
        Matcher code = SHORT_CODE.matcher(path);
        if (code.matches()) {
            return APP_BASE + "unlock?code=" + code.group(1);
        }
        StringBuilder url = new StringBuilder(APP_BASE).append(path.substring(1));
        if (uri.getEncodedQuery() != null) {
            url.append('?').append(uri.getEncodedQuery());
        }
        if (uri.getEncodedFragment() != null) {
            url.append('#').append(uri.getEncodedFragment());
        }
        return url.toString();
    }

    /** Encoded path that always starts with "/". */
    private static String pathOf(Uri uri) {
        String path = uri.getEncodedPath();
        if (path == null || path.isEmpty()) {
            return "/";
        }
        return path.startsWith("/") ? path : "/" + path;
    }

    private void openExternally(Uri uri) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (ActivityNotFoundException ignored) {
            // No app can handle this link; nothing else to do.
        }
    }

    /** Serves files from the bundled website and decides which links stay inside the app. */
    private final class SiteWebViewClient extends WebViewClient {

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            Uri uri = request.getUrl();
            String scheme = uri.getScheme();
            String host = uri.getHost();
            boolean web = "https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme);

            if (web && APP_HOST.equalsIgnoreCase(host)) {
                // A six-digit short code typed or clicked inside the site goes to the unlock page.
                if (SHORT_CODE.matcher(pathOf(uri)).matches()) {
                    view.loadUrl(toLocalUrl(uri));
                    return true;
                }
                return false;
            }

            if (web && SITE_HOST.equalsIgnoreCase(host)) {
                view.loadUrl(toLocalUrl(uri));
                return true;
            }

            if (web) {
                // Destination pages of links (Redirect.html) and other websites open in the browser.
                openExternally(uri);
                return true;
            }

            if ("mailto".equalsIgnoreCase(scheme) || "tel".equalsIgnoreCase(scheme)
                    || "sms".equalsIgnoreCase(scheme) || "geo".equalsIgnoreCase(scheme)) {
                openExternally(uri);
                return true;
            }

            // about:, blob:, data: and similar are handled by the WebView itself.
            return false;
        }

        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri uri = request.getUrl();
            if (!APP_HOST.equalsIgnoreCase(uri.getHost())) {
                return null; // Supabase, images and other remote resources use the network.
            }
            return serveAsset(uri);
        }
    }

    /** Returns the bundled file for a virtual-origin URL, or a 404 response. */
    private WebResourceResponse serveAsset(Uri uri) {
        String relative = Uri.decode(pathOf(uri)).substring(1);
        if (relative.contains("..")) {
            return notFound();
        }

        AssetManager assets = getAssets();
        try {
            if (relative.isEmpty()) {
                relative = "index.html";
            } else if (relative.endsWith("/")) {
                relative = relative + "index.html";
            } else if (isDirectory(assets, relative)) {
                // Clean URL such as /unlock maps to unlock/index.html.
                relative = relative + "/index.html";
            }

            String mime = mimeType(relative);
            boolean binary = mime.startsWith("image/") || mime.startsWith("font/")
                    || "application/octet-stream".equals(mime);

            Map<String, String> headers = new HashMap<>();
            headers.put("Access-Control-Allow-Origin", "*");

            WebResourceResponse response = new WebResourceResponse(
                    mime, binary ? null : "UTF-8", assets.open(relative));
            response.setResponseHeaders(headers);
            return response;
        } catch (IOException e) {
            return notFound();
        }
    }

    private static boolean isDirectory(AssetManager assets, String path) throws IOException {
        String[] children = assets.list(path);
        return children != null && children.length > 0;
    }

    private static WebResourceResponse notFound() {
        return new WebResourceResponse("text/plain", "UTF-8", 404, "Not Found", null,
                new ByteArrayInputStream(new byte[0]));
    }

    private static String mimeType(String fileName) {
        int dot = fileName.lastIndexOf('.');
        String extension = dot >= 0 ? fileName.substring(dot + 1).toLowerCase(Locale.ROOT) : "";
        switch (extension) {
            case "html":
            case "htm":
                return "text/html";
            case "js":
            case "mjs":
                return "application/javascript";
            case "css":
                return "text/css";
            case "json":
                return "application/json";
            case "svg":
                return "image/svg+xml";
            default:
                String type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
                return type != null ? type : "application/octet-stream";
        }
    }
}
