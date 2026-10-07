"use strict";

const elements = Object.fromEntries([
  "fileInput", "dropZone", "assetList", "referenceName", "stage", "stageScroller", "emptyHint",
  "statusText", "stageWidth", "stageHeight", "viewZoom", "viewZoomValue", "targetCell",
  "composeButton", "separateButton", "centerButton", "clearButton", "exportPartButton",
  "exportCompositeButton", "noSelection", "inspector", "selectedThumb", "selectedRole",
  "selectedName", "referenceHelp", "sourceCell", "sourceCellValue", "sourceCellHelp", "autoReferenceRow",
  "autoReferenceToggle", "partScale", "scaleValue",
  "partX", "partY", "paletteMode", "whiteTransparentToggle", "visibilityToggle", "sourceSize",
  "logicalSize", "outputSize", "setReferenceButton", "removeButton", "resetScaleButton",
  "matchReferenceButton", "openMonoPixelButton", "closeMonoPixelButton", "monoPixelDialog",
  "monoPixelFrame", "cacheState", "editInMonoButton"
].map((id) => [id, document.getElementById(id)]));

const stageContext = elements.stage.getContext("2d", { alpha: true });
const state = {
  assets: [],
  selectedId: null,
  referenceId: null,
  viewZoom: 8,
  stageWidth: 160,
  stageHeight: 120,
  targetCell: 4,
  drag: null,
  pan: null,
  nextId: 1
};
const launchParams = new URLSearchParams(location.search);
const assemblyDatabaseName = launchParams.has("selftest") ? "ink-attack-pixel-studio-selftest" : "ink-attack-pixel-studio";
let assemblyDatabasePromise;
let persistenceReady = false;
let saveTimer;
let saveRevision = 0;
let saveQueue = Promise.resolve();
let indexedDatabaseUnavailable = false;
let persistenceBackend = "indexeddb";
let monoPixelReady = false;
let pendingMonoMessage = null;

bindEvents();
resizeStage();
renderAll(false);
initializeApplication();

async function initializeApplication() {
  if (launchParams.has("selftest")) {
    document.body.dataset.appReady = "true";
    await runSelfTest();
  } else {
    await restoreLastAssembly();
    persistenceReady = true;
    document.body.dataset.appReady = "true";
  }
  if (launchParams.has("mono")) requestAnimationFrame(openMonoPixelEditor);
}

function bindEvents() {
  elements.fileInput.addEventListener("change", (event) => importFiles(event.target.files));
  elements.dropZone.addEventListener("click", () => elements.fileInput.click());
  elements.dropZone.addEventListener("dragenter", onDragEnter);
  elements.dropZone.addEventListener("dragover", onDragEnter);
  elements.dropZone.addEventListener("dragleave", () => elements.dropZone.classList.remove("dragging"));
  elements.dropZone.addEventListener("drop", (event) => {
    event.preventDefault();
    elements.dropZone.classList.remove("dragging");
    importFiles(event.dataTransfer.files);
  });

  elements.composeButton.addEventListener("click", composeAssets);
  elements.separateButton.addEventListener("click", separateAssets);
  elements.centerButton.addEventListener("click", centerSelected);
  elements.clearButton.addEventListener("click", clearAssets);
  elements.exportPartButton.addEventListener("click", exportAllParts);
  elements.exportCompositeButton.addEventListener("click", exportComposite);
  elements.setReferenceButton.addEventListener("click", setSelectedAsReference);
  elements.removeButton.addEventListener("click", removeSelected);
  elements.resetScaleButton.addEventListener("click", () => updateSelected({ scale: 1 }));
  elements.matchReferenceButton.addEventListener("click", matchReferenceUnit);
  elements.editInMonoButton.addEventListener("click", editSelectedInMono);
  elements.openMonoPixelButton.addEventListener("click", openMonoPixelEditor);
  elements.closeMonoPixelButton.addEventListener("click", closeMonoPixelEditor);
  elements.monoPixelDialog.addEventListener("click", (event) => {
    if (event.target === elements.monoPixelDialog) closeMonoPixelEditor();
  });
  elements.monoPixelFrame.addEventListener("load", () => {
    monoPixelReady = true;
    flushMonoPixelMessage();
  });
  window.addEventListener("message", onMonoPixelMessage);

  elements.stageWidth.addEventListener("change", updateStageSize);
  elements.stageHeight.addEventListener("change", updateStageSize);
  elements.viewZoom.addEventListener("input", () => {
    state.viewZoom = Number(elements.viewZoom.value);
    elements.viewZoomValue.value = `${state.viewZoom}×`;
    resizeStage();
    renderStage();
    scheduleAssemblySave();
  });
  elements.targetCell.addEventListener("change", () => {
    state.targetCell = Number(elements.targetCell.value);
    renderInspector();
    scheduleAssemblySave();
  });

  elements.sourceCell.addEventListener("input", onSourceCellInput);
  elements.autoReferenceToggle.addEventListener("change", onAutoReferenceChanged);
  elements.partScale.addEventListener("input", () => updateSelected({ scale: Number(elements.partScale.value) / 100 }, true));
  elements.partX.addEventListener("change", () => updateSelected({ x: Number(elements.partX.value) || 0 }));
  elements.partY.addEventListener("change", () => updateSelected({ y: Number(elements.partY.value) || 0 }));
  elements.paletteMode.addEventListener("change", () => updateSelected({ paletteMode: elements.paletteMode.value }, true));
  elements.whiteTransparentToggle.addEventListener("change", () => updateSelected({ whiteTransparent: elements.whiteTransparentToggle.checked }, true));
  elements.visibilityToggle.addEventListener("change", () => updateSelected({ visible: elements.visibilityToggle.checked }));

  elements.stage.addEventListener("pointerdown", beginStageDrag);
  elements.stageScroller.addEventListener("wheel", routeStageWheel, { passive: false });
  elements.stageScroller.addEventListener("pointerdown", beginViewportPan);
  window.addEventListener("pointermove", moveStageDrag);
  window.addEventListener("pointermove", moveViewportPan);
  window.addEventListener("pointerup", endStageDrag);
  window.addEventListener("pointerup", endViewportPan);
  window.addEventListener("pointercancel", endViewportPan);
  window.addEventListener("keydown", onKeyDown);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") queueAssemblySave();
  });
}

function onDragEnter(event) {
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
  elements.dropZone.classList.add("dragging");
}

async function importFiles(fileList) {
  const files = [...fileList].filter((file) => file.type.startsWith("image/") || /\.(png|webp)$/i.test(file.name));
  if (!files.length) return setStatus("没有可导入的 PNG/WebP 图片", true);
  setStatus(`正在读取 ${files.length} 张图片…`);
  for (const file of files) {
    try {
      const url = URL.createObjectURL(file);
      const image = await loadImage(url);
      const detectedCell = detectUniformCellSize(image);
      const reference = findAsset(state.referenceId);
      const sourceCell = reference ? calculateReferenceDrivenCell(image, reference) : detectedCell;
      const id = state.nextId++;
      const expression = /(face|common|sad|angry|furious|surpris|表情|悲伤|生气|惊讶|愤怒)/i.test(file.name);
      const logicalWidth = Math.max(1, Math.round(image.naturalWidth / sourceCell));
      const logicalHeight = Math.max(1, Math.round(image.naturalHeight / sourceCell));
      const offset = state.assets.length * 4;
      state.assets.push({
        id, name: file.name, url, image, blob: file, sourceCell, detectedCell, scale: 1,
        autoFromReference: Boolean(reference),
        x: Math.round((state.stageWidth - logicalWidth) / 2) + offset,
        y: Math.round((state.stageHeight - logicalHeight) / 2) + offset,
        paletteMode: "mono4", binary: false, whiteTransparent: !expression, visible: true, cacheKey: "", processed: null
      });
      if (state.referenceId === null) state.referenceId = id;
      state.selectedId = id;
    } catch (error) {
      console.error(error);
      setStatus(`无法读取 ${file.name}`, true);
    }
  }
  elements.fileInput.value = "";
  renderAll();
  const reference = findAsset(state.referenceId);
  const density = reference ? referenceLogicalDensity(reference) : 0;
  setStatus(`已导入 ${files.length} 张图片；后续部件已按参考图短边 ${formatNumber(density)} 个逻辑像素自动重新生成`);
}

function openMonoPixelEditor() {
  if (typeof elements.monoPixelDialog.showModal === "function") elements.monoPixelDialog.showModal();
  else elements.monoPixelDialog.setAttribute("open", "");
  setStatus("MONO PIXEL 已打开；编辑完成后点击“导入拼装台”");
}

function closeMonoPixelEditor() {
  if (elements.monoPixelDialog.open && typeof elements.monoPixelDialog.close === "function") elements.monoPixelDialog.close();
  else elements.monoPixelDialog.removeAttribute("open");
}

async function onMonoPixelMessage(event) {
  if (event.source !== elements.monoPixelFrame.contentWindow) return;
  const payload = event.data;
  if (!payload) return;
  if (payload.type === "mono-pixel:ready") {
    monoPixelReady = true;
    flushMonoPixelMessage();
    return;
  }
  if (payload.type !== "mono-pixel:import" || !(payload.blob instanceof Blob)) return;
  try {
    await importMonoPixelBlob(payload.blob, payload.name, payload.logicalWidth, payload.logicalHeight, payload.cellSize, payload.replaceAssetId);
    closeMonoPixelEditor();
  } catch (error) {
    console.error(error);
    setStatus("MONO PIXEL 部件导入失败", true);
  }
}

async function editSelectedInMono() {
  const asset = selectedAsset();
  if (!asset) return setStatus("请先选择要编辑的部件", true);
  const logicalCanvas = getProcessed(asset);
  const blob = await canvasToBlob(logicalCanvas);
  if (!blob) return setStatus("无法生成 MONO PIXEL 编辑源", true);
  pendingMonoMessage = {
    type: "ink-assembly:edit",
    name: `${baseName(asset.name)}-mono-source.png`,
    blob,
    sourceAssetId: asset.id
  };
  openMonoPixelEditor();
  flushMonoPixelMessage();
  setStatus(`已将 ${asset.name} 送入 MONO PIXEL；完成后会回写当前部件`);
}

function flushMonoPixelMessage() {
  if (!monoPixelReady || !pendingMonoMessage || !elements.monoPixelFrame.contentWindow) return;
  elements.monoPixelFrame.contentWindow.postMessage(pendingMonoMessage, "*");
  pendingMonoMessage = null;
}

async function importMonoPixelBlob(blob, name = "mono-pixel-transparent.png", logicalWidth = 0, logicalHeight = 0, cellSize = 16, replaceAssetId = null) {
  const url = URL.createObjectURL(blob);
  try {
    const image = await loadImage(url);
    const expectedWidth = Math.max(1, Math.round(Number(logicalWidth) || image.naturalWidth / cellSize));
    const expectedHeight = Math.max(1, Math.round(Number(logicalHeight) || image.naturalHeight / cellSize));
    const exactCellX = image.naturalWidth / expectedWidth;
    const exactCellY = image.naturalHeight / expectedHeight;
    const sourceCell = Math.abs(exactCellX - exactCellY) < .001 ? exactCellX : Number(cellSize) || 16;
    const replacement = findAsset(Number(replaceAssetId));
    if (replacement) {
      URL.revokeObjectURL(replacement.url);
      Object.assign(replacement, {
        name: name || replacement.name,
        url,
        image,
        blob,
        sourceCell,
        detectedCell: sourceCell,
        scale: 1,
        autoFromReference: false,
        paletteMode: "mono4",
        binary: false,
        whiteTransparent: false,
        cacheKey: "",
        processed: null,
        source: "mono-pixel"
      });
      state.selectedId = replacement.id;
      if (replacement.id === state.referenceId) regenerateReferenceFollowers();
      renderAll();
      setStatus(`已从 MONO PIXEL 回写 ${replacement.name}：${expectedWidth} × ${expectedHeight} 逻辑格，拼装位置保持不变`);
      return replacement;
    }
    const id = state.nextId++;
    const offset = state.assets.length * 4;
    state.assets.push({
      id,
      name: name || "mono-pixel-transparent.png",
      url,
      image,
      blob,
      sourceCell,
      detectedCell: sourceCell,
      scale: 1,
      autoFromReference: false,
      x: Math.round((state.stageWidth - expectedWidth) / 2) + offset,
      y: Math.round((state.stageHeight - expectedHeight) / 2) + offset,
      paletteMode: "mono4",
      binary: false,
      whiteTransparent: false,
      visible: true,
      cacheKey: "",
      processed: null,
      source: "mono-pixel"
    });
    if (state.referenceId === null) state.referenceId = id;
    state.selectedId = id;
    renderAll();
    setStatus(`已从 MONO PIXEL 导入 ${expectedWidth} × ${expectedHeight} 逻辑格；保持编辑器原始网格`);
    return findAsset(id);
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  }
}

function canvasToBlob(canvas) {
  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}

function openAssemblyDatabase() {
  if (assemblyDatabasePromise) return assemblyDatabasePromise;
  assemblyDatabasePromise = withDatabaseTimeout(new Promise((resolve, reject) => {
    const request = indexedDB.open(assemblyDatabaseName, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains("projects")) request.result.createObjectStore("projects");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("数据库升级被其他窗口阻止"));
  }), "打开本地缓存").catch((error) => {
    assemblyDatabasePromise = undefined;
    throw error;
  });
  return assemblyDatabasePromise;
}

function withDatabaseTimeout(promise, operation, milliseconds = 1200) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${operation}超时`)), milliseconds);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function readIndexedAssembly() {
  const database = await openAssemblyDatabase();
  return withDatabaseTimeout(new Promise((resolve, reject) => {
    const transaction = database.transaction("projects", "readonly");
    const request = transaction.objectStore("projects").get("last");
    request.onsuccess = () => resolve(request.result || null);
    request.onerror = () => reject(request.error);
    transaction.onabort = () => reject(transaction.error || new Error("读取事务已中止"));
  }), "读取本地缓存");
}

async function writeIndexedAssembly(project) {
  const database = await openAssemblyDatabase();
  return withDatabaseTimeout(new Promise((resolve, reject) => {
    const transaction = database.transaction("projects", "readwrite");
    transaction.objectStore("projects").put(project, "last");
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error || new Error("保存事务已中止"));
  }), "写入本地缓存");
}

async function deleteIndexedAssembly() {
  const database = await openAssemblyDatabase();
  return withDatabaseTimeout(new Promise((resolve, reject) => {
    const transaction = database.transaction("projects", "readwrite");
    transaction.objectStore("projects").delete("last");
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error || new Error("清理事务已中止"));
  }), "清理本地缓存");
}

const localAssemblyKey = `${assemblyDatabaseName}:last`;

async function readStoredAssembly() {
  if (!indexedDatabaseUnavailable) {
    try {
      const project = await readIndexedAssembly();
      if (project) {
        persistenceBackend = "indexeddb";
        return project;
      }
    } catch (error) {
      console.warn("IndexedDB unavailable; using local storage fallback", error);
      indexedDatabaseUnavailable = true;
    }
  }
  persistenceBackend = "localstorage";
  return readLocalAssembly();
}

async function writeStoredAssembly(project) {
  if (!indexedDatabaseUnavailable) {
    try {
      await writeIndexedAssembly(project);
      persistenceBackend = "indexeddb";
      return;
    } catch (error) {
      console.warn("IndexedDB unavailable; using local storage fallback", error);
      indexedDatabaseUnavailable = true;
    }
  }
  persistenceBackend = "localstorage";
  await writeLocalAssembly(project);
}

async function deleteStoredAssembly() {
  if (!indexedDatabaseUnavailable) {
    try {
      await deleteIndexedAssembly();
    } catch (error) {
      console.warn("IndexedDB cleanup unavailable", error);
      indexedDatabaseUnavailable = true;
    }
  }
  localStorage.removeItem(localAssemblyKey);
}

async function writeLocalAssembly(project) {
  const assets = await Promise.all(project.assets.map(async (asset) => ({
    ...asset,
    blob: undefined,
    dataUrl: await blobToDataUrl(asset.blob)
  })));
  localStorage.setItem(localAssemblyKey, JSON.stringify({ ...project, assets }));
}

function readLocalAssembly() {
  const raw = localStorage.getItem(localAssemblyKey);
  if (!raw) return null;
  const project = JSON.parse(raw);
  project.assets = (project.assets || []).map((asset) => ({
    ...asset,
    blob: dataUrlToBlob(asset.dataUrl)
  }));
  return project;
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

function dataUrlToBlob(dataUrl) {
  const [header, encoded] = String(dataUrl || "").split(",");
  if (!encoded) return new Blob();
  const mime = /data:([^;]+)/.exec(header)?.[1] || "image/png";
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return new Blob([bytes], { type: mime });
}

function captureAssemblySnapshot() {
  return {
    version: 1,
    savedAt: Date.now(),
    selectedId: state.selectedId,
    referenceId: state.referenceId,
    viewZoom: state.viewZoom,
    stageWidth: state.stageWidth,
    stageHeight: state.stageHeight,
    targetCell: state.targetCell,
    assets: state.assets.filter((asset) => asset.blob instanceof Blob).map((asset) => ({
      id: asset.id,
      name: asset.name,
      blob: asset.blob,
      sourceCell: asset.sourceCell,
      detectedCell: asset.detectedCell,
      scale: asset.scale,
      autoFromReference: asset.autoFromReference,
      x: asset.x,
      y: asset.y,
      binary: asset.binary,
      paletteMode: asset.paletteMode || (asset.binary === false ? "original" : "binary"),
      whiteTransparent: asset.whiteTransparent,
      visible: asset.visible,
      source: asset.source || "file"
    }))
  };
}

function scheduleAssemblySave() {
  if (!persistenceReady) return;
  const revision = ++saveRevision;
  clearTimeout(saveTimer);
  elements.cacheState.textContent = "等待自动保存…";
  saveTimer = setTimeout(() => queueAssemblySave(revision), 350);
}

function queueAssemblySave(revision = ++saveRevision) {
  if (!persistenceReady) return;
  clearTimeout(saveTimer);
  const snapshot = captureAssemblySnapshot();
  saveQueue = saveQueue.catch(() => undefined).then(async () => {
    if (revision !== saveRevision) return;
    await writeStoredAssembly(snapshot);
    if (revision === saveRevision) {
      const time = new Date(snapshot.savedAt).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
      const backendLabel = persistenceBackend === "indexeddb" ? "" : " · 兼容模式";
      elements.cacheState.textContent = `已自动保存 ${time}${backendLabel}`;
      document.body.dataset.cacheState = "saved";
    }
  }).catch((error) => {
    console.error(error);
    elements.cacheState.textContent = "本地缓存保存失败";
    document.body.dataset.cacheState = "error";
  });
}

function clearStoredAssembly() {
  clearTimeout(saveTimer);
  ++saveRevision;
  saveQueue = saveQueue.catch(() => undefined).then(deleteStoredAssembly).then(() => {
    elements.cacheState.textContent = "缓存已清空";
    document.body.dataset.cacheState = "cleared";
  }).catch((error) => {
    console.error(error);
    elements.cacheState.textContent = "缓存清理失败";
  });
}

async function restoreLastAssembly() {
  try {
    const project = await readStoredAssembly();
    if (!project || project.version !== 1 || !Array.isArray(project.assets) || !project.assets.length) {
      elements.cacheState.textContent = "尚无本地记录";
      document.body.dataset.cacheRestore = "empty";
      return;
    }
    const restoredAssets = [];
    for (const saved of project.assets) {
      if (!(saved.blob instanceof Blob)) continue;
      const url = URL.createObjectURL(saved.blob);
      try {
        const image = await loadImage(url);
        restoredAssets.push({
          id: Number(saved.id),
          name: saved.name || "cached-part.png",
          blob: saved.blob,
          url,
          image,
          sourceCell: clamp(Number(saved.sourceCell) || 1, .25, 128),
          detectedCell: clamp(Number(saved.detectedCell) || Number(saved.sourceCell) || 1, .25, 128),
          scale: clamp(Number(saved.scale) || 1, .1, 4),
          autoFromReference: Boolean(saved.autoFromReference),
          x: Number(saved.x) || 0,
          y: Number(saved.y) || 0,
          paletteMode: saved.paletteMode || (saved.binary === false ? "original" : "binary"),
          binary: saved.binary !== false,
          whiteTransparent: Boolean(saved.whiteTransparent),
          visible: saved.visible !== false,
          source: saved.source || "file",
          cacheKey: "",
          processed: null
        });
      } catch (error) {
        URL.revokeObjectURL(url);
        console.error(error);
      }
    }
    if (!restoredAssets.length) {
      elements.cacheState.textContent = "缓存中没有可恢复图片";
      document.body.dataset.cacheRestore = "empty";
      return;
    }
    state.assets = restoredAssets;
    state.nextId = Math.max(...restoredAssets.map((asset) => asset.id), 0) + 1;
    state.stageWidth = clamp(Number(project.stageWidth) || 160, 16, 2048);
    state.stageHeight = clamp(Number(project.stageHeight) || 120, 16, 2048);
    state.viewZoom = clamp(Number(project.viewZoom) || 8, 3, 16);
    state.targetCell = [1, 2, 4, 8, 16].includes(Number(project.targetCell)) ? Number(project.targetCell) : 4;
    state.referenceId = restoredAssets.some((asset) => asset.id === Number(project.referenceId)) ? Number(project.referenceId) : restoredAssets[0].id;
    state.selectedId = restoredAssets.some((asset) => asset.id === Number(project.selectedId)) ? Number(project.selectedId) : restoredAssets.at(-1).id;
    elements.stageWidth.value = state.stageWidth;
    elements.stageHeight.value = state.stageHeight;
    elements.viewZoom.value = state.viewZoom;
    elements.viewZoomValue.value = `${state.viewZoom}×`;
    elements.targetCell.value = state.targetCell;
    resizeStage();
    renderAll(false);
    const savedTime = new Date(project.savedAt || Date.now()).toLocaleString("zh-CN", { hour12: false });
    const backendLabel = persistenceBackend === "indexeddb" ? "" : "（兼容模式）";
    elements.cacheState.textContent = `已恢复 ${restoredAssets.length} 个部件${backendLabel}`;
    document.body.dataset.cacheRestore = "pass";
    setStatus(`已恢复上次拼装记录（${savedTime}）`);
  } catch (error) {
    console.error(error);
    elements.cacheState.textContent = "本地缓存不可用";
    document.body.dataset.cacheRestore = "error";
  }
}

function referenceLogicalDensity(reference = findAsset(state.referenceId)) {
  if (!reference) return 0;
  return Math.min(reference.image.naturalWidth, reference.image.naturalHeight) / reference.sourceCell;
}

function calculateReferenceDrivenCell(image, reference = findAsset(state.referenceId)) {
  const density = referenceLogicalDensity(reference);
  if (!density) return detectUniformCellSize(image);
  return clamp(Math.min(image.naturalWidth, image.naturalHeight) / density, 0.25, 128);
}

function regenerateReferenceFollowers() {
  const reference = findAsset(state.referenceId);
  if (!reference) return;
  for (const asset of state.assets) {
    if (asset.id === reference.id || !asset.autoFromReference) continue;
    asset.sourceCell = calculateReferenceDrivenCell(asset.image, reference);
    invalidateAsset(asset);
  }
}

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = reject;
    image.src = url;
  });
}

function detectUniformCellSize(image) {
  const probe = document.createElement("canvas");
  probe.width = image.naturalWidth;
  probe.height = image.naturalHeight;
  const context = probe.getContext("2d", { willReadFrequently: true });
  context.drawImage(image, 0, 0);
  const pixels = context.getImageData(0, 0, probe.width, probe.height).data;
  const candidates = [64, 48, 32, 24, 16, 12, 10, 8, 6, 5, 4, 3, 2];
  for (const size of candidates) {
    if (probe.width % size || probe.height % size) continue;
    if (hasUniformCells(pixels, probe.width, probe.height, size)) return size;
  }
  return 1;
}

function hasUniformCells(pixels, width, height, cell) {
  for (let y = 0; y < height; y += cell) {
    for (let x = 0; x < width; x += cell) {
      const first = (y * width + x) * 4;
      for (let oy = 0; oy < cell; oy++) {
        for (let ox = 0; ox < cell; ox++) {
          const index = ((y + oy) * width + x + ox) * 4;
          if (pixels[index] !== pixels[first] || pixels[index + 1] !== pixels[first + 1] ||
              pixels[index + 2] !== pixels[first + 2] || pixels[index + 3] !== pixels[first + 3]) return false;
        }
      }
    }
  }
  return true;
}

function getProcessed(asset) {
  const cacheKey = [asset.sourceCell, asset.scale, asset.paletteMode || (asset.binary === false ? "original" : "binary"), asset.whiteTransparent].join("|");
  if (asset.processed && asset.cacheKey === cacheKey) return asset.processed;
  const logicalWidth = Math.max(1, Math.round(asset.image.naturalWidth / asset.sourceCell));
  const logicalHeight = Math.max(1, Math.round(asset.image.naturalHeight / asset.sourceCell));
  const reduced = createCanvas(logicalWidth, logicalHeight);
  const reducedContext = reduced.getContext("2d");
  reducedContext.imageSmoothingEnabled = false;
  reducedContext.drawImage(asset.image, 0, 0, logicalWidth, logicalHeight);

  const scaledWidth = Math.max(1, Math.round(logicalWidth * asset.scale));
  const scaledHeight = Math.max(1, Math.round(logicalHeight * asset.scale));
  const output = createCanvas(scaledWidth, scaledHeight);
  const context = output.getContext("2d", { willReadFrequently: true });
  context.imageSmoothingEnabled = false;
  context.drawImage(reduced, 0, 0, scaledWidth, scaledHeight);
  applyPixelRules(context, scaledWidth, scaledHeight, asset);
  asset.processed = output;
  asset.cacheKey = cacheKey;
  return output;
}

function applyPixelRules(context, width, height, asset) {
  const paletteMode = asset.paletteMode || (asset.binary === false ? "original" : "binary");
  if (paletteMode === "original" && !asset.whiteTransparent) return;
  const imageData = context.getImageData(0, 0, width, height);
  const data = imageData.data;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] < 8) { data[i + 3] = 0; continue; }
    if (paletteMode !== "original") {
      const luminance = data[i] * .2126 + data[i + 1] * .7152 + data[i + 2] * .0722;
      const value = paletteMode === "mono4" ? Math.round(luminance / 85) * 85 : luminance <= 128 ? 0 : 255;
      data[i] = data[i + 1] = data[i + 2] = value;
      data[i + 3] = 255;
    }
    if (asset.whiteTransparent && data[i] >= 250 && data[i + 1] >= 250 && data[i + 2] >= 250) {
      data[i] = data[i + 1] = data[i + 2] = data[i + 3] = 0;
    }
  }
  context.putImageData(imageData, 0, 0);
}

function renderAll(persist = true) {
  renderAssetList();
  renderInspector();
  renderStage();
  const reference = findAsset(state.referenceId);
  elements.referenceName.textContent = reference ? reference.name : "尚未选择";
  elements.emptyHint.hidden = state.assets.length > 0;
  if (persist) scheduleAssemblySave();
}

function renderAssetList() {
  elements.assetList.replaceChildren();
  for (const asset of state.assets) {
    const card = document.createElement("article");
    card.className = `asset-card${asset.id === state.selectedId ? " selected" : ""}${asset.id === state.referenceId ? " reference" : ""}`;
    card.innerHTML = `<img alt=""><div class="asset-copy"><strong></strong><small></small></div>${asset.id === state.referenceId ? '<span class="asset-badge">参考</span>' : ""}`;
    card.querySelector("img").src = asset.url;
    card.querySelector("strong").textContent = asset.name;
    const mode = asset.autoFromReference ? "自动参考" : "手动";
    card.querySelector("small").textContent = `${formatNumber(asset.sourceCell)}px → 1逻辑格 · ${Math.round(asset.scale * 100)}% · ${mode}`;
    card.addEventListener("click", () => { state.selectedId = asset.id; renderAll(); });
    elements.assetList.append(card);
  }
}

function renderInspector() {
  const asset = selectedAsset();
  elements.noSelection.hidden = Boolean(asset);
  elements.inspector.hidden = !asset;
  if (!asset) return;
  const processed = getProcessed(asset);
  elements.selectedThumb.src = asset.url;
  elements.selectedName.textContent = asset.name;
  elements.selectedRole.textContent = asset.id === state.referenceId
    ? "核心参考图"
    : asset.source === "mono-pixel"
      ? "MONO PIXEL 直导部件"
      : asset.autoFromReference ? "自动跟随参考的部件" : "手动校准部件";
  elements.referenceHelp.hidden = asset.id !== state.referenceId;
  elements.sourceCell.value = asset.sourceCell;
  elements.sourceCellValue.value = `${formatNumber(asset.sourceCell)} px`;
  elements.autoReferenceRow.hidden = asset.id === state.referenceId;
  elements.autoReferenceToggle.checked = asset.autoFromReference;
  elements.sourceCellHelp.textContent = asset.id === state.referenceId
    ? `参考图短边当前包含 ${formatNumber(referenceLogicalDensity(asset))} 个逻辑像素。修改后会重新生成所有自动跟随部件。`
    : asset.autoFromReference
      ? "由核心参考图自动计算；当前图片会以相同的短边逻辑像素数量重新采样。"
      : "已关闭自动跟随，可手动指定源图中一个逻辑格占多少像素。";
  elements.partScale.value = Math.round(asset.scale * 100);
  elements.scaleValue.value = `${Math.round(asset.scale * 100)}%`;
  elements.partX.value = asset.x;
  elements.partY.value = asset.y;
  elements.paletteMode.value = asset.paletteMode || (asset.binary === false ? "original" : "binary");
  elements.whiteTransparentToggle.checked = asset.whiteTransparent;
  elements.visibilityToggle.checked = asset.visible;
  elements.sourceSize.textContent = `${asset.image.naturalWidth} × ${asset.image.naturalHeight}px`;
  elements.logicalSize.textContent = `${processed.width} × ${processed.height}格`;
  elements.outputSize.textContent = `${processed.width * state.targetCell} × ${processed.height * state.targetCell}px`;
  elements.setReferenceButton.disabled = asset.id === state.referenceId;
}

function renderStage() {
  const zoom = state.viewZoom;
  stageContext.clearRect(0, 0, elements.stage.width, elements.stage.height);
  drawCheckerboard(stageContext, elements.stage.width, elements.stage.height, zoom);
  stageContext.imageSmoothingEnabled = false;
  for (const asset of state.assets) {
    if (!asset.visible) continue;
    const processed = getProcessed(asset);
    stageContext.drawImage(processed, asset.x * zoom, asset.y * zoom, processed.width * zoom, processed.height * zoom);
    if (asset.id === state.referenceId) drawOutline(asset, "#79e6c1", 2);
    if (asset.id === state.selectedId) drawOutline(asset, "#ffb45d", 2);
  }
}

function drawCheckerboard(context, width, height, size) {
  context.fillStyle = "#e5eaf0";
  context.fillRect(0, 0, width, height);
  context.fillStyle = "#cbd3dd";
  for (let y = 0; y < height; y += size) {
    for (let x = (Math.floor(y / size) % 2) * size; x < width; x += size * 2) context.fillRect(x, y, size, size);
  }
}

function drawOutline(asset, color, width) {
  const processed = getProcessed(asset);
  stageContext.strokeStyle = color;
  stageContext.lineWidth = width;
  stageContext.setLineDash(asset.id === state.referenceId ? [7, 4] : []);
  stageContext.strokeRect(asset.x * state.viewZoom + 1, asset.y * state.viewZoom + 1,
    processed.width * state.viewZoom - 2, processed.height * state.viewZoom - 2);
  stageContext.setLineDash([]);
}

function resizeStage() {
  elements.stage.width = state.stageWidth * state.viewZoom;
  elements.stage.height = state.stageHeight * state.viewZoom;
}

function updateStageSize() {
  state.stageWidth = clamp(Number(elements.stageWidth.value) || 160, 16, 2048);
  state.stageHeight = clamp(Number(elements.stageHeight.value) || 120, 16, 2048);
  elements.stageWidth.value = state.stageWidth;
  elements.stageHeight.value = state.stageHeight;
  resizeStage();
  renderStage();
  scheduleAssemblySave();
}

function updateSelected(changes, invalidate = false) {
  const asset = selectedAsset();
  if (!asset) return;
  Object.assign(asset, changes);
  if (invalidate) invalidateAsset(asset);
  renderAll();
}


function onSourceCellInput() {
  const asset = selectedAsset();
  if (!asset) return;
  asset.sourceCell = Number(elements.sourceCell.value);
  if (asset.id !== state.referenceId) asset.autoFromReference = false;
  invalidateAsset(asset);
  if (asset.id === state.referenceId) regenerateReferenceFollowers();
  renderAll();
}


function onAutoReferenceChanged() {
  const asset = selectedAsset();
  if (!asset || asset.id === state.referenceId) return;
  asset.autoFromReference = elements.autoReferenceToggle.checked;
  if (asset.autoFromReference) asset.sourceCell = calculateReferenceDrivenCell(asset.image);
  invalidateAsset(asset);
  renderAll();
}


function invalidateAsset(asset) {
  asset.cacheKey = "";
  asset.processed = null;
}


function setSelectedAsReference() {
  const selected = selectedAsset();
  if (!selected) return;
  const oldReference = findAsset(state.referenceId);
  state.referenceId = state.selectedId;
  selected.autoFromReference = false;
  if (oldReference && oldReference.id !== selected.id) oldReference.autoFromReference = true;
  regenerateReferenceFollowers();
  renderAll();
  setStatus(`${selected.name} 已设为核心参考；所有自动跟随部件已按它的逻辑像素密度重新生成`);
}

function matchReferenceUnit() {
  const asset = selectedAsset();
  const reference = findAsset(state.referenceId);
  if (!asset || !reference) return;
  if (asset.id !== reference.id) {
    asset.autoFromReference = true;
    asset.sourceCell = calculateReferenceDrivenCell(asset.image, reference);
  }
  asset.scale = 1;
  invalidateAsset(asset);
  renderAll();
  setStatus(`${asset.name} 已按参考图自动重新像素化，并恢复为 100% 逻辑缩放`);
}

function composeAssets() {
  if (!state.assets.length) return;
  const reference = findAsset(state.referenceId) || state.assets[0];
  const referenceImage = getProcessed(reference);
  reference.x = Math.round((state.stageWidth - referenceImage.width) / 2);
  reference.y = Math.round((state.stageHeight - referenceImage.height) / 2);
  const centerX = reference.x + referenceImage.width / 2;
  const centerY = reference.y + referenceImage.height / 2;
  for (const asset of state.assets) {
    if (asset === reference) continue;
    const image = getProcessed(asset);
    asset.x = Math.round(centerX - image.width / 2);
    asset.y = Math.round(centerY - image.height / 2);
  }
  renderAll();
  setStatus("已将所有部件按核心参考图中心拼接；可直接拖动微调层位置");
}

function separateAssets() {
  let x = 6, y = 6, rowHeight = 0;
  for (const asset of state.assets) {
    const image = getProcessed(asset);
    if (x + image.width + 6 > state.stageWidth) { x = 6; y += rowHeight + 6; rowHeight = 0; }
    asset.x = x; asset.y = y;
    x += image.width + 6;
    rowHeight = Math.max(rowHeight, image.height);
  }
  renderAll();
  setStatus("所有部件已拆开平铺，可分别检查逻辑像素大小");
}

function centerSelected() {
  const asset = selectedAsset();
  if (!asset) return;
  const image = getProcessed(asset);
  asset.x = Math.round((state.stageWidth - image.width) / 2);
  asset.y = Math.round((state.stageHeight - image.height) / 2);
  renderAll();
}

function beginStageDrag(event) {
  if (event.button !== 0) return;
  const point = stagePoint(event);
  const hit = [...state.assets].reverse().find((asset) => asset.visible && pointInAsset(point, asset));
  if (!hit) return;
  state.selectedId = hit.id;
  state.drag = { pointerId: event.pointerId, offsetX: point.x - hit.x, offsetY: point.y - hit.y };
  elements.stage.setPointerCapture(event.pointerId);
  elements.stage.classList.add("dragging");
  renderAll();
}

function routeStageWheel(event) {
  if (event.ctrlKey) return;
  const scroller = elements.stageScroller;
  const unit = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 18 : event.deltaMode === WheelEvent.DOM_DELTA_PAGE ? scroller.clientHeight : 1;
  const horizontalDelta = event.shiftKey ? (event.deltaY || event.deltaX) * unit : event.deltaX * unit;
  const verticalDelta = event.shiftKey ? 0 : event.deltaY * unit;
  const previousLeft = scroller.scrollLeft;
  const previousTop = scroller.scrollTop;
  scroller.scrollLeft = clamp(previousLeft + horizontalDelta, 0, Math.max(0, scroller.scrollWidth - scroller.clientWidth));
  scroller.scrollTop = clamp(previousTop + verticalDelta, 0, Math.max(0, scroller.scrollHeight - scroller.clientHeight));
  if (scroller.scrollLeft !== previousLeft || scroller.scrollTop !== previousTop) event.preventDefault();
}

function beginViewportPan(event) {
  if (event.button !== 1) return;
  event.preventDefault();
  state.pan = {
    pointerId: event.pointerId,
    clientX: event.clientX,
    clientY: event.clientY,
    scrollLeft: elements.stageScroller.scrollLeft,
    scrollTop: elements.stageScroller.scrollTop
  };
  elements.stageScroller.classList.add("panning");
  elements.stageScroller.setPointerCapture?.(event.pointerId);
}

function moveViewportPan(event) {
  if (!state.pan || event.pointerId !== state.pan.pointerId) return;
  elements.stageScroller.scrollLeft = state.pan.scrollLeft - (event.clientX - state.pan.clientX);
  elements.stageScroller.scrollTop = state.pan.scrollTop - (event.clientY - state.pan.clientY);
}

function endViewportPan(event) {
  if (!state.pan || event.pointerId !== state.pan.pointerId) return;
  state.pan = null;
  elements.stageScroller.classList.remove("panning");
}

function moveStageDrag(event) {
  if (!state.drag || event.pointerId !== state.drag.pointerId) return;
  const asset = selectedAsset();
  const point = stagePoint(event);
  asset.x = Math.round(point.x - state.drag.offsetX);
  asset.y = Math.round(point.y - state.drag.offsetY);
  elements.partX.value = asset.x;
  elements.partY.value = asset.y;
  renderStage();
}

function endStageDrag(event) {
  if (!state.drag || event.pointerId !== state.drag.pointerId) return;
  state.drag = null;
  elements.stage.classList.remove("dragging");
  renderInspector();
  scheduleAssemblySave();
}

function stagePoint(event) {
  const rect = elements.stage.getBoundingClientRect();
  return {
    x: (event.clientX - rect.left) * elements.stage.width / rect.width / state.viewZoom,
    y: (event.clientY - rect.top) * elements.stage.height / rect.height / state.viewZoom
  };
}

function pointInAsset(point, asset) {
  const image = getProcessed(asset);
  return point.x >= asset.x && point.y >= asset.y && point.x < asset.x + image.width && point.y < asset.y + image.height;
}

function onKeyDown(event) {
  const asset = selectedAsset();
  if (!asset || /INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)) return;
  if (event.key === "Delete") { removeSelected(); event.preventDefault(); return; }
  const delta = event.shiftKey ? 5 : 1;
  if (event.key === "ArrowLeft") asset.x -= delta;
  else if (event.key === "ArrowRight") asset.x += delta;
  else if (event.key === "ArrowUp") asset.y -= delta;
  else if (event.key === "ArrowDown") asset.y += delta;
  else return;
  event.preventDefault();
  renderAll();
}

function removeSelected() {
  const asset = selectedAsset();
  if (!asset) return;
  const removedReference = state.referenceId === asset.id;
  URL.revokeObjectURL(asset.url);
  state.assets = state.assets.filter((candidate) => candidate.id !== asset.id);
  if (removedReference) {
    state.referenceId = state.assets[0]?.id ?? null;
    const newReference = findAsset(state.referenceId);
    if (newReference) {
      newReference.autoFromReference = false;
      regenerateReferenceFollowers();
    }
  }
  state.selectedId = state.assets.at(-1)?.id ?? null;
  renderAll();
}

function clearAssets() {
  for (const asset of state.assets) URL.revokeObjectURL(asset.url);
  state.assets = [];
  state.selectedId = null;
  state.referenceId = null;
  renderAll(false);
  clearStoredAssembly();
  setStatus("已清空素材");
}

async function exportAllParts() {
  if (!state.assets.length) return setStatus("请先导入部件", true);
  if (!("showDirectoryPicker" in window)) {
    return setStatus("当前浏览器不支持选择导出文件夹，请使用最新版 Chrome 或 Edge", true);
  }
  let directory;
  try {
    directory = await window.showDirectoryPicker({ mode: "readwrite", id: "ink-attack-part-export" });
    await ensureDirectoryWritePermission(directory);
  } catch (error) {
    if (error.name === "AbortError") return setStatus("已取消导出");
    console.error(error);
    return setStatus("无法打开文件夹选择窗口", true);
  }
  try {
    const exported = await writeAllPartsToDirectory(directory);
    setStatus(`已将 ${exported.length} 个部件导出到所选文件夹；每逻辑像素 ${state.targetCell}×${state.targetCell}px`);
  } catch (error) {
    console.error(error);
    const completed = Number(error.completed) || 0;
    const progress = completed ? `（已完成 ${completed} 个）` : "";
    setStatus(`批量导出中断${progress}：${describeExportError(error)}`, true);
  }
}

function createPartExportManifest() {
  const usedNames = new Set();
  return state.assets.map((asset) => {
    const stem = `${safeWindowsStem(asset.name)}_normalized_${state.targetCell}x`;
    let filename = `${stem}.png`;
    let suffix = 2;
    while (usedNames.has(filename.toLowerCase())) filename = `${stem}_${suffix++}.png`;
    usedNames.add(filename.toLowerCase());
    return { asset, filename };
  });
}

function safeWindowsStem(name) {
  let stem = baseName(name).replace(/[. ]+$/g, "").slice(0, 96) || "part";
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(stem)) stem = `_${stem}`;
  return stem;
}

async function ensureDirectoryWritePermission(directory) {
  if (typeof directory.queryPermission !== "function") return;
  let permission = await directory.queryPermission({ mode: "readwrite" });
  if (permission === "prompt" && typeof directory.requestPermission === "function") {
    permission = await directory.requestPermission({ mode: "readwrite" });
  }
  if (permission !== "granted") throw new DOMException("没有所选文件夹的写入权限", "NotAllowedError");
}

function describeExportError(error) {
  if (error.name === "NotFoundError") return "所选文件夹或文件句柄已失效。请再次点击“导出全部部件”，并选择未被移动的本地文件夹；云盘目录请先确认已同步到本机";
  if (error.name === "NotAllowedError" || error.name === "SecurityError") return "浏览器没有该文件夹的写入权限，请再次导出并允许读写权限";
  if (error.name === "QuotaExceededError") return "目标磁盘空间不足或浏览器写入额度已满";
  if (error.name === "InvalidModificationError") return "目标位置中的同名项目不是普通文件，请更换文件夹或重命名冲突项目";
  return error.message || "未知文件写入错误，请更换一个本地文件夹后重试";
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function writeBlobWithRetry(directory, filename, blob, attempts = 3) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    let writable;
    try {
      const fileHandle = await directory.getFileHandle(filename, { create: true });
      writable = await fileHandle.createWritable({ keepExistingData: false });
      await writable.write(blob);
      await writable.close();
      return;
    } catch (error) {
      lastError = error;
      if (writable && typeof writable.abort === "function") {
        try { await writable.abort(); } catch (_) {}
      }
      if (!['NotFoundError', 'InvalidStateError', 'NoModificationAllowedError'].includes(error.name) || attempt === attempts) break;
      await delay(120 * attempt);
    }
  }
  throw lastError;
}

async function writeAllPartsToDirectory(directory) {
  await ensureDirectoryWritePermission(directory);
  const manifest = createPartExportManifest();
  const exported = [];
  for (let index = 0; index < manifest.length; index++) {
    const { asset, filename } = manifest[index];
    setStatus(`正在导出 ${index + 1} / ${manifest.length}：${asset.name}`);
    const output = expandLogicalCanvas(getProcessed(asset), state.targetCell);
    const blob = await canvasToBlob(output);
    if (!blob) throw new Error(`${asset.name} 无法生成 PNG`);
    try {
      await writeBlobWithRetry(directory, filename, blob);
    } catch (error) {
      error.completed = exported.length;
      error.assetName = asset.name;
      error.filename = filename;
      throw error;
    }
    exported.push({ filename, blob });
  }
  return exported;
}

function exportComposite() {
  if (!state.assets.length) return setStatus("请先导入部件", true);
  const logical = createCanvas(state.stageWidth, state.stageHeight);
  const context = logical.getContext("2d");
  context.imageSmoothingEnabled = false;
  for (const asset of state.assets) if (asset.visible) context.drawImage(getProcessed(asset), asset.x, asset.y);
  downloadCanvas(expandLogicalCanvas(logical, state.targetCell), `inkman_composite_${state.targetCell}x.png`);
  setStatus(`已导出拼接图：${state.stageWidth * state.targetCell} × ${state.stageHeight * state.targetCell}px`);
}

function expandLogicalCanvas(logical, cell) {
  const output = createCanvas(logical.width * cell, logical.height * cell);
  const context = output.getContext("2d");
  context.imageSmoothingEnabled = false;
  context.drawImage(logical, 0, 0, output.width, output.height);
  return output;
}

function downloadCanvas(canvas, filename) {
  canvas.toBlob((blob) => {
    if (!blob) return setStatus("浏览器无法生成 PNG", true);
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }, "image/png");
}

function createCanvas(width, height) {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  return canvas;
}

function selectedAsset() { return findAsset(state.selectedId); }
function findAsset(id) { return state.assets.find((asset) => asset.id === id) || null; }
function baseName(name) { return name.replace(/\.[^.]+$/, "").replace(/[^\w\u4e00-\u9fff-]+/g, "_"); }
function clamp(value, minimum, maximum) { return Math.max(minimum, Math.min(maximum, value)); }
function formatNumber(value) { return Number(value.toFixed(3)).toString(); }
function setStatus(message, error = false) {
  elements.statusText.textContent = message;
  elements.statusText.style.color = error ? "#ff7c82" : "";
}

async function runSelfTest() {
  try {
    const source = createCanvas(8, 8);
    const context = source.getContext("2d");
    context.clearRect(0, 0, 8, 8);
    context.fillStyle = "#000";
    context.fillRect(0, 0, 4, 4);
    context.fillRect(4, 4, 4, 4);
    context.fillStyle = "#fff";
    context.fillRect(4, 0, 4, 4);
    const blob = await new Promise((resolve) => source.toBlob(resolve, "image/png"));
    await importFiles([new File([blob], "selftest.png", { type: "image/png" })]);
    const reference = selectedAsset();
    const processed = getProcessed(reference);
    const expanded = expandLogicalCanvas(processed, 4);
    if (reference.sourceCell !== 4 || processed.width !== 2 || processed.height !== 2 || expanded.width !== 8 || expanded.height !== 8) {
      throw new Error("reference-grid conversion mismatch");
    }
    const followerSource = createCanvas(12, 18);
    const followerContext = followerSource.getContext("2d");
    const gradient = followerContext.createLinearGradient(0, 0, 12, 18);
    gradient.addColorStop(0, "#111");
    gradient.addColorStop(1, "#eee");
    followerContext.fillStyle = gradient;
    followerContext.fillRect(0, 0, 12, 18);
    const followerBlob = await new Promise((resolve) => followerSource.toBlob(resolve, "image/png"));
    await importFiles([new File([followerBlob], "follower.png", { type: "image/png" })]);
    const follower = selectedAsset();
    const followerProcessed = getProcessed(follower);
    if (!follower.autoFromReference || Math.abs(follower.sourceCell - 6) > .001 || followerProcessed.width !== 2 || followerProcessed.height !== 3) {
      throw new Error("follower was not regenerated from reference density");
    }
    if (!elements.emptyHint.hidden || getComputedStyle(elements.emptyHint).display !== "none") {
      throw new Error("empty-stage hint is still visible after import");
    }
    const monoSource = createCanvas(48, 32);
    const monoContext = monoSource.getContext("2d");
    monoContext.fillStyle = "#000";
    monoContext.fillRect(0, 0, 16, 16);
    monoContext.fillRect(32, 16, 16, 16);
    const monoBlob = await new Promise((resolve) => monoSource.toBlob(resolve, "image/png"));
    const monoAsset = await importMonoPixelBlob(monoBlob, "mono-selftest.png", 3, 2, 16);
    const monoProcessed = getProcessed(monoAsset);
    if (monoAsset.sourceCell !== 16 || monoAsset.autoFromReference || monoProcessed.width !== 3 || monoProcessed.height !== 2) {
      throw new Error("MONO PIXEL direct import did not preserve its logical grid");
    }
    const previousCount = state.assets.length;
    const previousX = monoAsset.x;
    const previousY = monoAsset.y;
    const replacementSource = createCanvas(32, 16);
    replacementSource.getContext("2d").fillRect(0, 0, 16, 16);
    const replacementBlob = await canvasToBlob(replacementSource);
    const replacedAsset = await importMonoPixelBlob(replacementBlob, "mono-roundtrip.png", 2, 1, 16, monoAsset.id);
    if (state.assets.length !== previousCount || replacedAsset.id !== monoAsset.id || replacedAsset.x !== previousX || replacedAsset.y !== previousY || getProcessed(replacedAsset).width !== 2) {
      throw new Error("selected asset MONO PIXEL roundtrip did not replace in place");
    }
    const paletteProbe = createCanvas(4, 1);
    const paletteContext = paletteProbe.getContext("2d", { willReadFrequently: true });
    const palettePixels = paletteContext.createImageData(4, 1);
    [10, 80, 160, 245].forEach((value, index) => {
      palettePixels.data[index * 4] = value;
      palettePixels.data[index * 4 + 1] = value;
      palettePixels.data[index * 4 + 2] = value;
      palettePixels.data[index * 4 + 3] = 255;
    });
    paletteContext.putImageData(palettePixels, 0, 0);
    applyPixelRules(paletteContext, 4, 1, { paletteMode: "mono4", whiteTransparent: false });
    const paletteResult = paletteContext.getImageData(0, 0, 4, 1).data;
    const paletteTones = [paletteResult[0], paletteResult[4], paletteResult[8], paletteResult[12]];
    if (paletteTones.join(",") !== "0,85,170,255") throw new Error("MONO four-tone palette mismatch");
    document.body.dataset.paletteSelfTest = "pass";
    const fakeExports = [];
    const fakeAttempts = new Map();
    const fakeDirectory = {
      async getFileHandle(filename) {
        return {
          async createWritable() {
            const attempt = (fakeAttempts.get(filename) || 0) + 1;
            fakeAttempts.set(filename, attempt);
            if (attempt === 1) throw new DOMException('temporary missing handle', 'NotFoundError');
            return {
              async write(exportedBlob) { fakeExports.push({ filename, exportedBlob }); },
              async close() {}
            };
          }
        };
      }
    };
    const exportedParts = await writeAllPartsToDirectory(fakeDirectory);
    if (exportedParts.length !== state.assets.length || fakeExports.some((item) => !(item.exportedBlob instanceof Blob)) || new Set(fakeExports.map((item) => item.filename)).size !== fakeExports.length || [...fakeAttempts.values()].some((attempts) => attempts !== 2)) {
      throw new Error("bulk part export failed");
    }
    document.body.dataset.bulkExportSelfTest = "pass";
    const previousScrollTop = elements.stageScroller.scrollTop;
    elements.stageScroller.scrollTop = 0;
    elements.stageScroller.dispatchEvent(new WheelEvent("wheel", { deltaY: 120, bubbles: true, cancelable: true }));
    if (elements.stageScroller.scrollHeight > elements.stageScroller.clientHeight && elements.stageScroller.scrollTop <= 0) {
      throw new Error("assembly stage vertical wheel navigation failed");
    }
    elements.stageScroller.scrollTop = previousScrollTop;
    document.body.dataset.stageWheelSelfTest = "pass";
    const cacheSnapshot = captureAssemblySnapshot();
    document.body.dataset.cacheTestStage = "before-write";
    await writeStoredAssembly(cacheSnapshot);
    document.body.dataset.cacheTestStage = "after-write";
    const cachedProject = await readStoredAssembly();
    document.body.dataset.cacheTestStage = "after-read";
    if (!cachedProject || cachedProject.assets.length !== state.assets.length || !(cachedProject.assets[0].blob instanceof Blob)) {
      throw new Error("assembly cache roundtrip failed");
    }
    await deleteStoredAssembly();
    document.body.dataset.cacheTestStage = "after-delete";
    document.body.dataset.cacheSelfTest = "pass";
    document.body.dataset.selfTest = "pass";
    setStatus("浏览器自检通过：批量导出、自动缓存、四阶灰度与 MONO PIXEL 往返编辑均正常");
  } catch (error) {
    console.error(error);
    document.body.dataset.selfTest = "fail";
    setStatus(`浏览器自检失败：${error.message}`, true);
  }
}

window.InkPixelStudio = {
  state,
  detectUniformCellSize,
  getProcessed,
  expandLogicalCanvas,
  calculateReferenceDrivenCell,
  importMonoPixelBlob,
  openMonoPixelEditor,
  createPartExportManifest,
  writeAllPartsToDirectory,
  composeAssets,
  separateAssets
};
