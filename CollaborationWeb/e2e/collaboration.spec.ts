import { expect, test, type Page } from '@playwright/test';
async function addText(page: Page, text: string, y = 160) {
  await page.getByRole('button', { name: 'Add text', exact: true }).click();
  await page.getByRole('img', { name: 'Shared canvas' }).click({ position: { x: 150, y } });
  await page.getByRole('textbox', { name: 'Text to add' }).fill(text);
  await page.getByRole('button', { name: 'Add to canvas', exact: true }).click();
  await expect(page.getByText(text, { exact: true })).toBeVisible();
}
for (const relay of [false, true]) {
  test(`public signaling, ${relay ? 'forced TURN relay' : 'automatic ICE'}, text, pen, laser, reconnect, and owner disconnect`, async ({ browser, baseURL }) => {
    const hostContext = await browser.newContext(), guestContext = await browser.newContext();
    if (relay && process.env.MB_ICE_SERVERS) for (const context of [hostContext, guestContext]) await context.addInitScript(servers => { localStorage.setItem('mb-force-relay', 'yes'); localStorage.setItem('mb-ice-servers', servers); }, process.env.MB_ICE_SERVERS);
    else if (relay) for (const context of [hostContext, guestContext]) await context.addInitScript(() => localStorage.setItem('mb-force-relay', 'yes'));
    await guestContext.addInitScript(() => {
      const original = window.RTCPeerConnection;
      const connections: RTCPeerConnection[] = [];
      (window as any).__collaborationConnections = connections;
      window.RTCPeerConnection = class extends original { constructor(configuration?: RTCConfiguration) { super(configuration); connections.push(this); } };
    });
    const host = await hostContext.newPage(), guest = await guestContext.newPage();
    await host.goto(baseURL!); await host.getByRole('button', { name: 'Host a demo board' }).click();
    await expect(host.getByRole('status')).toContainText('Browser sharing ready', { timeout: 30000 });
    await host.getByRole('button', { name: 'Invite', exact: true }).click();
    const link = await host.getByRole('textbox', { name: 'Session link' }).inputValue();
    await expect(host.getByRole('img', { name: 'Session invitation QR code' })).toBeVisible();
    await host.getByRole('button', { name: 'Close invitation' }).click();
    await guest.goto(baseURL!);
    await guest.getByPlaceholder('Paste the session link').fill(link);
    await guest.getByRole('button', { name: 'Join session', exact: true }).click();
    await expect(guest.getByRole('button', { name: 'Add text', exact: true })).toBeEnabled({ timeout: 45000 });
    if (relay) await expect(guest.getByRole('status')).toContainText('relay', { timeout: 10000 });
    await addText(guest, 'Guest writes a shared equation');
    await expect(host.getByText('Guest writes a shared equation', { exact: true })).toBeVisible();
    await addText(host, 'Host replies', 240); await expect(guest.getByText('Host replies', { exact: true })).toBeVisible();
    await guest.getByRole('button', { name: 'Pen', exact: true }).click();
    const paper = (await guest.getByRole('img', { name: 'Shared canvas' }).boundingBox())!;
    await guest.mouse.move(paper.x + 200, paper.y + 270); await guest.mouse.down();
    await guest.mouse.move(paper.x + 380, paper.y + 320, { steps: 20 }); await guest.mouse.up();
    await expect(host.locator('polyline[data-object-id]')).toHaveCount(1);
    const revision = await host.getByTestId('revision').innerText();
    await guest.getByRole('button', { name: 'Laser pointer', exact: true }).click();
    await guest.mouse.move(paper.x + 240, paper.y + 280); await guest.mouse.down();
    await guest.mouse.move(paper.x + 300, paper.y + 290, { steps: 4 });
    await expect(host.locator('[data-laser]')).toHaveCount(1); await expect(guest.locator('[data-laser]')).toHaveCount(1); await guest.mouse.up();
    await expect(host.locator('[data-laser]')).toHaveCount(0, { timeout: 5000 });
    await expect(host.getByTestId('revision')).toHaveText(revision);
    // Close the guest WebRTC connections through the browser's network stack. This retains
    // the replica and exercises transport reconnection rather than reloading a new document.
    await guest.evaluate(() => (window as any).__collaborationConnections.forEach((connection: RTCPeerConnection) => connection.close()));
    await expect(guest.getByRole('button', { name: 'Add text', exact: true })).toBeDisabled();
    await addText(host, 'While guest is away', 340);
    await expect(guest.getByText('While guest is away', { exact: true })).toBeVisible({ timeout: 30000 });
    await guest.getByRole('button', { name: 'Undo my last addition' }).click();
    await expect(host.locator('polyline[data-object-id]')).toHaveCount(0);
    await host.screenshot({ path: `test-results/${relay ? 'relay' : 'direct'}-host.png` });
    await host.getByRole('button', { name: 'End session' }).click();
    await expect(guest.getByRole('button', { name: 'Add text', exact: true })).toBeDisabled();
    await expect(guest.getByRole('alert')).toContainText('host ended');
    await hostContext.close(); await guestContext.close();
  });
}

test('relay settings validate JSON and persist a provider configuration', async ({ page, baseURL }) => {
  await page.goto(baseURL!); await page.getByRole('button', { name: 'Connection options', exact: true }).click();
  const field = page.getByRole('textbox', { name: 'Provider ICE servers JSON' });
  await field.fill('not JSON'); await page.getByRole('button', { name: 'Save relay settings' }).click();
  await expect(page.getByText('Enter valid ICE servers JSON.', { exact: true })).toBeVisible();
  const config = [{ urls: 'turns:relay.example:443?transport=tcp', username: 'test', credential: 'test' }];
  await field.fill(JSON.stringify(config)); await page.getByRole('button', { name: 'Save relay settings' }).click();
  await expect(page.getByText('Saved for the next connection.', { exact: true })).toBeVisible();
  await page.reload(); await page.getByRole('button', { name: 'Connection options', exact: true }).click();
  await expect(field).toHaveValue(JSON.stringify(config));
  await field.fill(''); await page.getByRole('button', { name: 'Save relay settings' }).click();
  expect(await page.evaluate(() => localStorage.getItem('mb-ice-servers'))).toBeNull();
});

test('page background larger than a JSON data channel survives transfer', async ({ browser, baseURL }) => {
  const hostContext = await browser.newContext(), guestContext = await browser.newContext();
  await hostContext.addInitScript(() => {
    const session = crypto.randomUUID(), document = crypto.randomUUID(), page = crypto.randomUUID(), secondPage = crypto.randomUUID();
    (window as any).__secondPage = secondPage;
    const invite = { v: 1, session, document, token: crypto.randomUUID() + crypto.randomUUID(), peer: 'mb-' + session, nearby: 'mb-test' };
    (window as any).webkit = { messageHandlers: { collaboration: { postMessage(message: any) {
      if (message.type === 'ready') queueMicrotask(() => (window as any).mbNative.startHost({ document: { id: document, title: 'Imported lecture', pages: [{ id: page, width: 612, height: 792 }, { id: secondPage, width: 792, height: 612 }], objects: [], revision: 0 }, invite, publicURL: location.href }));
      if (message.type === 'persist') queueMicrotask(() => (window as any).mbNative.saved(message.mutation.id));
      if (message.type === 'backgroundRequest') {
        const canvas = documentObject.createElement('canvas'); canvas.width = 900; canvas.height = 1100;
        const context = canvas.getContext('2d')!, pixels = context.createImageData(900, 1100);
        let state = 12345;
        for (let i = 0; i < pixels.data.length; i += 4) { state = (state * 1664525 + 1013904223) >>> 0; pixels.data[i] = state & 255; pixels.data[i + 1] = state >>> 8 & 255; pixels.data[i + 2] = state >>> 16 & 255; pixels.data[i + 3] = 255; }
        context.putImageData(pixels, 0, 0);
        const data = canvas.toDataURL('image/jpeg', 0.7);
        (window as any).__background = data;
        queueMicrotask(() => (window as any).mbNative.background(message.pageID, data));
      }
    } } } };
    const documentObject = window.document;
  });
  const host = await hostContext.newPage(), guest = await guestContext.newPage();
  await host.goto(baseURL!); await expect(host.getByRole('status')).toContainText('Browser sharing ready', { timeout: 30000 });
  const background = await host.evaluate(() => (window as any).__background as string);
  expect(background.length).toBeGreaterThan(16300);
  await host.getByRole('button', { name: 'Invite', exact: true }).click();
  const link = await host.getByRole('textbox', { name: 'Session link' }).inputValue();
  await host.getByRole('button', { name: 'Close invitation' }).click(); await guest.goto(link);
  await expect(guest.locator('.paper image')).toHaveAttribute('href', background, { timeout: 30000 });
  const paper = (await guest.getByRole('img', { name: 'Shared canvas' }).boundingBox())!;
  expect(paper.width / paper.height).toBeCloseTo(612 / 792, 2);
  await addText(guest, 'Text over imported content');
  await expect(host.getByText('Text over imported content', { exact: true })).toBeVisible();
  await guest.getByRole('button', { name: 'Pen', exact: true }).click();
  // More than 16 KB of samples exercises chunking for an edit as well as its background.
  await guest.mouse.move(paper.x + 100, paper.y + 100); await guest.mouse.down();
  for (let i = 0; i < 800; i++) await guest.getByRole('img', { name: 'Shared canvas' }).dispatchEvent('pointermove', { pointerId: 1, clientX: paper.x + 120 + i % 100, clientY: paper.y + 200 + i % 80 });
  await guest.mouse.move(paper.x + 210, paper.y + 260); await guest.mouse.up();
  await expect(host.locator('polyline[data-object-id]')).toHaveCount(1);
  // Each participant can select another page without mixing page overlays.
  await guest.getByRole('combobox', { name: 'Page', exact: true }).selectOption({ label: 'Page 2 of 2' });
  await expect(guest.locator('.paper image')).toHaveAttribute('href', background);
  const landscape = (await guest.getByRole('img', { name: 'Shared canvas' }).boundingBox())!;
  expect(landscape.width / landscape.height).toBeCloseTo(792 / 612, 2);
  await expect(guest.locator('polyline[data-object-id]')).toHaveCount(0);
  await addText(guest, 'Only on the second page');
  await expect(host.getByText('Only on the second page', { exact: true })).toHaveCount(0);
  await host.getByRole('combobox', { name: 'Page', exact: true }).selectOption({ label: 'Page 2 of 2' });
  await expect(host.getByText('Only on the second page', { exact: true })).toBeVisible();
  await guest.getByRole('combobox', { name: 'Page', exact: true }).selectOption({ label: 'Page 1 of 2' });
  await expect(guest.locator('polyline[data-object-id]')).toHaveCount(1);
  await hostContext.close(); await guestContext.close();
});
