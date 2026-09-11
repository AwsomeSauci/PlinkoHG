"""Optional WebGL acceptance check. Requires playwright, Pillow and installed Chrome.

Uses an isolated headless browser and temporary browser storage. It never opens a
window or accesses desktop player saves. Build the HTML5 bundle with Bob first.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from threading import Thread

from PIL import Image
from playwright.sync_api import sync_playwright


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('.internal/web-check'))
    parser.add_argument('--chrome', required=True)
    parser.add_argument('--mixed-rewards', action='store_true',
        help='Use a disposable fixture with 12 initial balls and every basket awarding 100 points, 2 balls and 3 leaves')
    args = parser.parse_args()
    if not (args.bundle / 'index.html').is_file():
        parser.error('--bundle must contain a built index.html')
    args.output.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(args.bundle.resolve())))
    Thread(target=server.serve_forever, daemon=True).start()
    logs = []
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=args.chrome, headless=True,
                args=['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--mute-audio'])
            context = browser.new_context(viewport={'width': 720, 'height': 1080})
            page = context.new_page()
            page.on('console', lambda message: logs.append(message.text))
            page.on('pageerror', lambda error: logs.append('PAGEERROR: ' + str(error)))
            page.goto(f'http://127.0.0.1:{server.server_port}/', wait_until='networkidle')
            canvas = page.locator('canvas')

            def ready():
                page.wait_for_function("typeof Module !== 'undefined' && Module.calledRun")
                page.wait_for_timeout(700)
                canvas.focus()

            def key(value):
                # A zero-duration down/up can fall between engine input polls.
                page.keyboard.press(value, delay=100)
                page.wait_for_timeout(100)

            def point(x, y):
                box = canvas.bounding_box()
                return box['x'] + x * box['width'] / 720, box['y'] + (1080-y) * box['height'] / 1080

            def pixels(rect):
                image = Image.open(BytesIO(canvas.screenshot())).convert('RGB')
                return image.crop(tuple(round(v * image.width / 720) for v in rect)).tobytes()

            def capture(name):
                canvas.screenshot(path=str(args.output / (name + '.png')))

            def same_pixels(a, b):
                # SDF glyph rasterization can differ by one channel level after
                # reload. A changed numeral is much larger than this tolerance.
                return len(a) == len(b) and all(abs(x-y) <= 2 for x, y in zip(a, b))

            stock_rect = (390, 112, 490, 160)
            score_rect = (68, 112, 308, 160)
            ready()
            if args.mixed_rewards:
                capture('mixed-initial')
                initial_stock, initial_score = pixels(stock_rect), pixels(score_rect)
                key('Space')
                pending_stock = pixels(stock_rect)
                assert not same_pixels(pending_stock, initial_stock)
                page.reload(wait_until='networkidle')
                ready()
                page.wait_for_timeout(4500)
                awarded_stock, awarded_score = pixels(stock_rect), pixels(score_rect)
                assert not same_pixels(awarded_stock, pending_stock)
                assert not same_pixels(awarded_stock, initial_stock)
                assert not same_pixels(awarded_score, initial_score)
                capture('mixed-awarded')
                page.reload(wait_until='networkidle')
                ready()
                page.wait_for_timeout(4500)
                assert same_pixels(awarded_stock, pixels(stock_rect)), 'Reload must retain ball rewards without paying twice'
                assert same_pixels(awarded_score, pixels(score_rect)), 'Reload must retain points without paying twice'
                key('d')
                capture('mixed-statistics')
                assert not any('ERROR:' in line or 'PAGEERROR:' in line for line in logs), '\n'.join(logs)
                print('PASS mixed WebGL: composite payout, pending reload, settled reload and inventory presentation')
                browser.close()
                return
            capture('initial')
            initial = pixels(stock_rect)
            page.mouse.move(*point(227, 203))
            page.mouse.down()
            page.wait_for_timeout(100)
            page.mouse.move(*point(360, 500))
            page.mouse.up()
            page.wait_for_timeout(150)
            assert same_pixels(pixels(stock_rect), initial), 'Pointer release outside must cancel the drop'
            page.mouse.click(*point(227, 203), delay=100)
            page.wait_for_timeout(150)
            assert not same_pixels(pixels(stock_rect), initial), 'Pointer click must debit inventory'
            key('b')
            key('b')
            remaining = pixels(stock_rect)  # 12 - 1 - 5 - 5 = 1
            page.mouse.click(*point(550, 203), delay=100)
            page.wait_for_timeout(100)
            assert same_pixels(pixels(stock_rect), remaining), 'Disabled batch button must not debit inventory'
            capture('pending-before-reload')
            page.reload(wait_until='networkidle')
            ready()
            assert same_pixels(pixels(stock_rect), remaining), 'Reload must not debit paid pending drops again'
            page.wait_for_timeout(4500)
            capture('settled-after-reload')
            score = pixels(score_rect)
            page.reload(wait_until='networkidle')
            ready()
            capture('settled-second-reload')
            assert same_pixels(pixels(score_rect), score), 'Settled rewards must survive reload without duplication'
            before_stats = pixels((70, 220, 650, 780))
            key('d')
            assert not same_pixels(pixels((70, 220, 650, 780)), before_stats), 'Statistics must open on D'
            capture('statistics')
            key('Escape')
            key('g')
            assert not same_pixels(pixels(stock_rect), remaining), 'Debug grant must add inventory'
            page.set_viewport_size({'width': 390, 'height': 844})
            page.wait_for_timeout(200)
            capture('portrait')
            page.set_viewport_size({'width': 1280, 'height': 720})
            page.wait_for_timeout(200)
            capture('landscape')
            context.close()
            browser.close()
        failures = [line for line in logs if 'ERROR:SCRIPT' in line or 'ERROR:RESOURCE' in line or 'PAGEERROR:' in line]
        assert not failures, '\n'.join(failures)
        print('PASS WebGL: startup, pointer cancellation, single/batch, disabled button, pending reload, settled reload, stats, grant, resize')
    finally:
        server.shutdown()
        server.server_close()
        (args.output / 'browser.log').write_text('\n'.join(logs), encoding='utf-8')


if __name__ == '__main__':
    main()
