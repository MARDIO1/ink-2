(() => {
  'use strict';

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const els = {
    fileInput: $('#fileInput'), pixelArtInput: $('#pixelArtInput'), dropzone: $('#dropzone'), uploadLabel: $('#uploadLabel'), sidebar: $('.sidebar'),
    batchPanel: $('#batchPanel'), batchCount: $('#batchCount'), batchList: $('#batchList'), clearBatch: $('#clearBatch'),
    width: $('#canvasWidth'), height: $('#canvasHeight'), size: $('#sizeOutput'), adaptiveCanvas: $('#adaptiveCanvas'), contrast: $('#contrast'), contrastOut: $('#contrastOutput'),
    threshold: $('#threshold'), thresholdOut: $('#thresholdOutput'), removeBg: $('#removeBg'), dither: $('#dither'),
    autoMerge: $('#autoMerge'), mergeStrength: $('#mergeStrength'), mergeStrengthOut: $('#mergeStrengthOutput'), mergeStrengthRow: $('#mergeStrengthRow'),
    toneOut: $('#toneOutput'), generate: $('#generateBtn'), empty: $('#emptyState'), demo: $('#demoBtn'),
    stage: $('#canvasStage'), scroller: $('#canvasScroller'), canvas: $('#pixelCanvas'), cursorTip: $('#cursorTip'),
    brushSizeControl: $('#brushSizeControl'), brushSizeDown: $('#brushSizeDown'), brushSizeUp: $('#brushSizeUp'), brushSizeOut: $('#brushSizeOutput'),
    undo: $('#undoBtn'), redo: $('#redoBtn'), outline: $('#outlineBtn'), merge: $('#mergeBtn'), expand: $('#expandBtn'), symmetryBtn: $('#symmetryBtn'), centerBtn: $('#centerBtn'), mirrorRightBtn: $('#mirrorRightBtn'), exportTop: $('#exportTop'), exportFloating: $('#exportFloating'),
    zoomIn: $('#zoomIn'), zoomOut: $('#zoomOut'), zoomOutText: $('#zoomOutput'), status: $('#statusText'), importAssembler: $('#importAssembler'), selectionSize: $('#selectionSize'),
    dims: $('#dimensionText'), count: $('#pixelCount'), saveState: $('#saveState'), toast: $('#toast'), expandDialog: $('#expandDialog'),
    batchNav: $('#batchNav'), batchPrev: $('#batchPrev'), batchNext: $('#batchNext'), batchPosition: $('#batchPosition'),
    expandForm: $('#expandForm'), dialogDims: $('#dialogDims'), expandTop: $('#expandTop'), expandRight: $('#expandRight'),
    expandBottom: $('#expandBottom'), expandLeft: $('#expandLeft')
  };

  const ctx = els.canvas.getContext('2d');
  const state = {
    image: null, imageName: '', cols: 80, rows: 80, pixels: [], original: [], levels: 4,
    tool: 'brush', color: 0, brushSize: 1, zoom: 1, cell: 12, cursor: { x: 0, y: 0 },
    pointerDown: false, strokeChanged: false, history: [], future: [], checker: true, symmetry: false,
    batchSources: [], batchResults: [], batchIndex: 0, batchProcessing: false,
    selectionStart: null, selectionEnd: null, lastSelectionSize: null
  };
  let toastTimer;
  let saveTimer;
  let projectDBPromise;
  let restoringProject = false;
  let assemblySourceAssetId = null;

  function openProjectDB() {
    if (projectDBPromise) return projectDBPromise;
    projectDBPromise = new Promise((resolve,reject)=>{
      const request=indexedDB.open('mono-pixel-projects',1);
      request.onupgradeneeded=()=>request.result.createObjectStore('projects');
      request.onsuccess=()=>resolve(request.result);
      request.onerror=()=>reject(request.error);
    });
    return projectDBPromise;
  }

  async function saveProjectNow() {
    if(!state.pixels.length||restoringProject) return;
    try{
      const db=await openProjectDB();
      const project={version:1,cols:state.cols,rows:state.rows,pixels:state.pixels.slice(),imageName:state.imageName||'mono-pixel-project',levels:state.levels,color:state.color,brushSize:state.brushSize,zoom:state.zoom,savedAt:Date.now()};
      await new Promise((resolve,reject)=>{const tx=db.transaction('projects','readwrite');tx.objectStore('projects').put(project,'last');tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});
      els.saveState.textContent='已自动保存';
    }catch(error){ els.saveState.textContent='自动保存不可用'; }
  }

  function scheduleProjectSave() {
    if(!state.pixels.length||restoringProject) return;
    els.saveState.textContent='正在保存…';
    clearTimeout(saveTimer);
    saveTimer=setTimeout(saveProjectNow,450);
  }

  async function restoreLastProject() {
    try{
      const db=await openProjectDB();
      const project=await new Promise((resolve,reject)=>{const tx=db.transaction('projects','readonly');const req=tx.objectStore('projects').get('last');req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);});
      if(!project||!Array.isArray(project.pixels)||project.pixels.length!==project.cols*project.rows) return;
      restoringProject=true;
      state.cols=project.cols; state.rows=project.rows; state.pixels=project.pixels; state.original=project.pixels.slice();
      state.imageName=project.imageName||'mono-pixel-project'; state.levels=project.levels||4; state.color=project.color??0;state.brushSize=project.brushSize||1;
      state.zoom=project.zoom||1; state.cursor={x:Math.floor(state.cols/2),y:Math.floor(state.rows/2)}; state.history=[]; state.future=[];
      els.width.value=clamp(state.cols,8,256); els.height.value=clamp(state.rows,8,256); els.size.textContent=`${state.cols} × ${state.rows}`;
      $$('.segmented button').forEach(b=>b.classList.toggle('active',Number(b.dataset.levels)===state.levels)); els.toneOut.textContent=`${state.levels} 阶`; setColor(state.color);setBrushSize(state.brushSize,false);
      fitCell(); setReady(true); updateHistoryUI(); draw();
      restoringProject=false; els.saveState.textContent='上次项目已恢复'; toast('已恢复上次编辑的项目');
    }catch(error){ restoringProject=false; els.saveState.textContent='本地自动保存'; }
  }

  const clamp = (n, min, max) => Math.min(max, Math.max(min, n));
  const samePixels = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
  function toast(message) {
    els.toast.textContent = message;
    els.toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => els.toast.classList.remove('show'), 1800);
  }

  function routeSidebarWheel(event) {
    if (event.ctrlKey || !els.sidebar.contains(event.target)) return;
    const maxScroll = Math.max(0, els.sidebar.scrollHeight - els.sidebar.clientHeight);
    if (!maxScroll) return;
    const unit = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 18 : event.deltaMode === WheelEvent.DOM_DELTA_PAGE ? els.sidebar.clientHeight : 1;
    const previous = els.sidebar.scrollTop;
    els.sidebar.scrollTop = clamp(previous + event.deltaY * unit, 0, maxScroll);
    if (els.sidebar.scrollTop !== previous) event.preventDefault();
  }

  function runSidebarScrollSelfTest() {
    const original = els.sidebar.scrollTop;
    els.sidebar.scrollTop = 0;
    const target = els.autoMerge.closest('.switch-row');
    target.dispatchEvent(new WheelEvent('wheel',{deltaY:120,bubbles:true,cancelable:true}));
    document.body.dataset.sidebarWheelTest = els.sidebar.scrollHeight<=els.sidebar.clientHeight||els.sidebar.scrollTop>0?'pass':'fail';
    els.sidebar.scrollTop=original;
  }

  function setReady(ready) {
    els.generate.disabled = !state.image;
    els.exportTop.disabled = !ready;
    els.importAssembler.disabled = !ready;
    els.exportFloating.disabled = !ready;
    els.exportFloating.hidden = !ready;
    els.outline.disabled = !ready;
    els.merge.disabled = !ready;
    els.expand.disabled = !ready;
    els.centerBtn.disabled = !ready;
    els.mirrorRightBtn.disabled = !ready;
    els.empty.hidden = ready;
    els.scroller.hidden = !ready;
    els.cursorTip.hidden = !ready;
    els.status.textContent = ready ? '编辑中' : state.image ? '图片已载入' : '就绪';
    if(!ready){state.selectionStart=null;state.selectionEnd=null;state.lastSelectionSize=null;updateSelectionReadout();}
  }

  function updateSizePreview() {
    const width = clamp(Number(els.width.value)||80,8,256);
    const height = clamp(Number(els.height.value)||80,8,256);
    els.size.textContent = `${width} × ${height}`;
  }

  function readFileAsImage(file) {
    return new Promise((resolve,reject)=>{
      const reader=new FileReader();
      reader.onload=()=>{const img=new Image();img.onload=()=>resolve({image:img,imageName:file.name.replace(/\.[^.]+$/,''),fileName:file.name});img.onerror=reject;img.src=reader.result;};
      reader.onerror=reject;reader.readAsDataURL(file);
    });
  }

  async function loadFiles(fileList,pixelPerfect=false,sourceAssetId=null) {
    const files=[...fileList].filter(file=>file&&file.type.startsWith('image/')&&file.size<=10*1024*1024);
    if(!files.length)return toast('请选择单张不超过 10MB 的图片文件');
    els.status.textContent='正在读取图片…';
    try{
      const loaded=await Promise.all(files.map(readFileAsImage));assemblySourceAssetId=sourceAssetId;
      state.batchSources=loaded.map(item=>({...item,pixelPerfect}));state.batchResults=[];state.batchIndex=0;
      state.image=loaded[0].image;state.imageName=loaded[0].imageName;
      els.uploadLabel.textContent=files.length>1?`已选择 ${files.length} 张图片`:files[0].name;
      updateSizePreview();setReady(false);updateBatchUI();
      els.generate.querySelector('span').textContent=files.length>1?`生成全部 ${files.length} 张`:'生成像素画';
      els.generate.disabled=false;els.status.textContent=`已载入 ${files.length} 张图片`;
      if(pixelPerfect) await generate();
      else toast(files.length>1?`已载入 ${files.length} 张，点击生成全部`:'图片已载入，点击生成');
    }catch(error){toast('部分图片读取失败，请重新选择');}
  }

  function loadFile(file,pixelPerfect=false){return loadFiles([file],pixelPerfect);}

  function syncCurrentBatch() {
    if(!state.batchResults.length||!state.batchResults[state.batchIndex])return;
    Object.assign(state.batchResults[state.batchIndex],{pixels:state.pixels,cols:state.cols,rows:state.rows,imageName:state.imageName});
  }

  function updateBatchUI() {
    const total=state.batchSources.length;
    els.batchPanel.hidden=total<2;els.batchNav.hidden=state.batchResults.length<2;
    els.batchCount.textContent=`${total} 张`;
    els.batchList.replaceChildren();
    state.batchSources.forEach((source,index)=>{
      const btn=document.createElement('button');btn.type='button';btn.className='batch-item';btn.textContent=String(index+1).padStart(2,'0');btn.title=source.fileName;
      btn.classList.toggle('done',Boolean(state.batchResults[index]));btn.classList.toggle('active',index===state.batchIndex);
      btn.addEventListener('click',()=>{if(state.batchResults[index])activateBatchResult(index);});els.batchList.appendChild(btn);
    });
    const readyTotal=state.batchResults.length;
    els.batchPosition.textContent=readyTotal?`${state.batchIndex+1} / ${readyTotal}`:'0 / 0';
    els.batchPrev.disabled=state.batchIndex<=0;els.batchNext.disabled=state.batchIndex>=readyTotal-1;
    const label=els.exportTop.querySelector('span');if(label)label.textContent=readyTotal>1?`导出全部 ${readyTotal} 张`:'导出 PNG';
  }

  function activateBatchResult(index) {
    if(!state.batchResults[index])return;
    syncCurrentBatch();state.batchIndex=index;
    const result=state.batchResults[index],source=state.batchSources[index];
    state.image=source?.image||null;state.imageName=result.imageName;state.cols=result.cols;state.rows=result.rows;state.pixels=result.pixels;state.original=result.pixels.slice();
    state.history=[];state.future=[];state.cursor={x:Math.floor(state.cols/2),y:Math.floor(state.rows/2)};state.zoom=1;state.selectionStart=null;state.selectionEnd=null;state.lastSelectionSize=null;
    els.size.textContent=`${state.cols} × ${state.rows}`;fitCell();setReady(true);updateHistoryUI();draw();updateBatchUI();
  }

  function clearBatch() {
    state.batchSources=[];state.batchResults=[];state.batchIndex=0;state.image=null;state.imageName='';state.pixels=[];state.selectionStart=null;state.selectionEnd=null;state.lastSelectionSize=null;
    els.uploadLabel.textContent='选择或拖入一系列图片';els.generate.querySelector('span').textContent='生成像素画';updateBatchUI();setReady(false);
  }

  function cornerBackground(data, w, h) {
    const points = [[0,0],[w-1,0],[0,h-1],[w-1,h-1]];
    const avg = [0,0,0]; let count = 0;
    points.forEach(([x,y]) => {
      const i = (y*w+x)*4;
      if (data[i+3] < 128) return;
      avg[0] += data[i]; avg[1] += data[i+1]; avg[2] += data[i+2]; count++;
    });
    return count ? avg.map(v => v / count) : null;
  }

  function grayscale(r, g, b) { return 0.2126*r + 0.7152*g + 0.0722*b; }
  function quantize(value, levels) {
    const step = 255 / (levels - 1);
    return Math.round(value / step) * step;
  }

  function detailMetrics(pixels,w,h,strength) {
    let adjacent=0,transitions=0,solid=0,smallComponents=0;
    const visited=new Uint8Array(pixels.length);
    const smallLimit=3+strength*3;
    for(let y=0;y<h;y++) for(let x=0;x<w;x++){
      const pos=y*w+x, value=pixels[pos];
      if(value===null) continue;
      solid++;
      if(x+1<w&&pixels[pos+1]!==null){adjacent++;if(pixels[pos+1]!==value)transitions++;}
      if(y+1<h&&pixels[pos+w]!==null){adjacent++;if(pixels[pos+w]!==value)transitions++;}
      if(visited[pos]) continue;
      const queue=[pos];visited[pos]=1;let size=0;
      for(let qi=0;qi<queue.length;qi++){
        const p=queue[qi],px=p%w,py=Math.floor(p/w);size++;
        for(const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1]]){
          const nx=px+dx,ny=py+dy;if(nx<0||ny<0||nx>=w||ny>=h)continue;
          const np=ny*w+nx;if(!visited[np]&&pixels[np]===value){visited[np]=1;queue.push(np);}
        }
      }
      if(size<=smallLimit)smallComponents++;
    }
    return {solid,transitionRate:adjacent?transitions/adjacent:0,smallComponents};
  }

  function simplifyColorBlocks(source,w,h,strength=3,force=false) {
    const metrics=detailMetrics(source,w,h,strength);
    const threshold=0.075-strength*0.012;
    const needsMerge=force||metrics.transitionRate>threshold||metrics.smallComponents>=Math.max(7,Math.round(metrics.solid/700));
    if(!needsMerge)return {pixels:source.slice(),changed:false,metrics};
    let current=source.slice();
    const radius=clamp(Math.max(strength>=3?2:1,Math.round((Math.max(w,h)/96)*(strength/3))),1,6);
    const passes=1+strength;
    for(let pass=0;pass<passes;pass++){
      const next=current.slice();
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const pos=y*w+x;if(source[pos]===null)continue;
        const votes=new Map();
        for(let dy=-radius;dy<=radius;dy++)for(let dx=-radius;dx<=radius;dx++){
          const nx=x+dx,ny=y+dy;if(nx<0||ny<0||nx>=w||ny>=h)continue;
          const v=current[ny*w+nx];if(v===null)continue;
          const weight=dx===0&&dy===0?1.35:1/(1+Math.max(Math.abs(dx),Math.abs(dy))*.35);
          votes.set(v,(votes.get(v)||0)+weight);
        }
        let best=current[pos],bestVote=-1;
        votes.forEach((vote,value)=>{if(vote>bestVote){bestVote=vote;best=value;}});
        next[pos]=best;
      }
      current=next;
    }
    const visited=new Uint8Array(current.length);
    const sizeScale=Math.max(1,Math.sqrt((w*h)/(80*80)));
    const minRegion=Math.max(3,Math.round(strength*strength*1.25*sizeScale));
    for(let start=0;start<current.length;start++){
      if(current[start]===null||visited[start])continue;
      const color=current[start],queue=[start],region=[];visited[start]=1;
      for(let qi=0;qi<queue.length;qi++){
        const p=queue[qi],x=p%w,y=Math.floor(p/w);region.push(p);
        for(const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1]]){
          const nx=x+dx,ny=y+dy;if(nx<0||ny<0||nx>=w||ny>=h)continue;
          const np=ny*w+nx;if(!visited[np]&&current[np]===color){visited[np]=1;queue.push(np);}
        }
      }
      if(region.length>=minRegion)continue;
      const neighbors=new Map();
      region.forEach(p=>{const x=p%w,y=Math.floor(p/w);for(const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1]]){const nx=x+dx,ny=y+dy;if(nx<0||ny<0||nx>=w||ny>=h)continue;const v=current[ny*w+nx];if(v!==null&&v!==color)neighbors.set(v,(neighbors.get(v)||0)+1);}});
      let replacement=color,best=0;neighbors.forEach((count,value)=>{if(count>best){best=count;replacement=value;}});
      if(replacement!==color)region.forEach(p=>current[p]=replacement);
    }
    const changed=!samePixels(current,source);
    return {pixels:current,changed,metrics};
  }

  function applyBlockMerge(force=true) {
    if(!state.pixels.length)return;
    const result=simplifyColorBlocks(state.pixels,state.cols,state.rows,Number(els.mergeStrength.value),force);
    if(!result.changed)return toast('当前色块已经足够简洁');
    snapshot();state.pixels=result.pixels;draw();
    toast('已合并零碎灰阶，外部轮廓保持不变');
  }

  function analyzeImageForCanvas(image) {
    const maxSample=128,scale=Math.min(1,maxSample/image.width,maxSample/image.height);
    const w=Math.max(1,Math.round(image.width*scale)),h=Math.max(1,Math.round(image.height*scale));
    const sample=document.createElement('canvas');sample.width=w;sample.height=h;
    const sctx=sample.getContext('2d',{willReadFrequently:true});sctx.drawImage(image,0,0,w,h);
    const data=sctx.getImageData(0,0,w,h).data,bg=cornerBackground(data,w,h),tolerance=Number(els.threshold.value)*2.35;
    const occupied=new Uint8Array(w*h),grayValues=new Float32Array(w*h);
    let minX=w,minY=h,maxX=-1,maxY=-1,count=0;
    for(let y=0;y<h;y++)for(let x=0;x<w;x++){
      const p=y*w+x,i=p*4,r=data[i],g=data[i+1],b=data[i+2],a=data[i+3],dist=bg?Math.hypot(r-bg[0],g-bg[1],b-bg[2]):Infinity;
      if(a<50||(els.removeBg.checked&&dist<tolerance))continue;
      occupied[p]=1;grayValues[p]=grayscale(r,g,b);count++;if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y;
    }
    if(maxX<0){minX=0;minY=0;maxX=w-1;maxY=h-1;}
    let edgePairs=0,strongEdges=0;
    for(let y=minY;y<=maxY;y++)for(let x=minX;x<=maxX;x++){
      const p=y*w+x;if(!occupied[p])continue;
      if(x<maxX&&occupied[p+1]){edgePairs++;if(Math.abs(grayValues[p]-grayValues[p+1])>24)strongEdges++;}
      if(y<maxY&&occupied[p+w]){edgePairs++;if(Math.abs(grayValues[p]-grayValues[p+w])>24)strongEdges++;}
    }
    const edgeDensity=edgePairs?strongEdges/edgePairs:0;
    const detail=clamp(edgeDensity*3.2+Math.min(.18,count/(w*h)*.12),0,1);
    const pad=2,minXP=clamp(minX-pad,0,w-1),minYP=clamp(minY-pad,0,h-1),maxXP=clamp(maxX+pad,0,w-1),maxYP=clamp(maxY+pad,0,h-1);
    const crop={x:minXP/scale,y:minYP/scale,w:(maxXP-minXP+1)/scale,h:(maxYP-minYP+1)/scale};
    const aspect=crop.w/crop.h,longSide=Math.round((56+detail*88)/4)*4;
    let cols,rows;if(aspect>=1){cols=longSide;rows=Math.round(longSide/aspect);}else{rows=longSide;cols=Math.round(longSide*aspect);}
    cols=clamp(cols,16,256);rows=clamp(rows,16,256);
    return {crop,bg,detail,cols,rows};
  }

  function processImageSource(source) {
    const image=source.image,analysis=analyzeImageForCanvas(image),pixelPerfect=Boolean(source.pixelPerfect);
    let cols,rows,crop,smoothing=true;
    if(pixelPerfect){const scale=Math.min(1,512/image.width,512/image.height);cols=Math.max(1,Math.round(image.width*scale));rows=Math.max(1,Math.round(image.height*scale));crop={x:0,y:0,w:image.width,h:image.height};smoothing=false;}
    else if(els.adaptiveCanvas.checked){cols=analysis.cols;rows=analysis.rows;crop=analysis.crop;}
    else{cols=clamp(Number(els.width.value)||80,8,256);rows=clamp(Number(els.height.value)||80,8,256);crop={x:0,y:0,w:image.width,h:image.height};}
    const work=document.createElement('canvas');work.width=cols;work.height=rows;
    const wctx=work.getContext('2d',{willReadFrequently:true});wctx.imageSmoothingEnabled=smoothing;wctx.imageSmoothingQuality='high';wctx.clearRect(0,0,cols,rows);
    const fit=Math.min(cols/crop.w,rows/crop.h),drawW=crop.w*fit,drawH=crop.h*fit,dx=(cols-drawW)/2,dy=(rows-drawH)/2;
    wctx.drawImage(image,crop.x,crop.y,crop.w,crop.h,dx,dy,drawW,drawH);
    const data=wctx.getImageData(0,0,cols,rows).data,bg=analysis.bg,tolerance=Number(els.threshold.value)*2.35;
    const contrast=(Number(els.contrast.value)+100)/100,values=new Array(cols*rows),errors=new Float32Array(values.length);
    for(let y=0;y<rows;y++)for(let x=0;x<cols;x++){
      const pos=y*cols+x,i=pos*4,r=data[i],g=data[i+1],b=data[i+2],a=data[i+3],dist=bg?Math.hypot(r-bg[0],g-bg[1],b-bg[2]):Infinity;
      if(a<50||(els.removeBg.checked&&dist<tolerance)){values[pos]=null;continue;}
      let gray=clamp((grayscale(r,g,b)-128)*contrast+128+errors[pos],0,255);const q=quantize(gray,state.levels);values[pos]=Math.round(q);
      if(els.dither.checked){const err=gray-q;if(x+1<cols)errors[pos+1]+=err*7/16;if(y+1<rows){if(x>0)errors[pos+cols-1]+=err*3/16;errors[pos+cols]+=err*5/16;if(x+1<cols)errors[pos+cols+1]+=err/16;}}
    }
    const merged=els.autoMerge.checked?simplifyColorBlocks(values,cols,rows,Number(els.mergeStrength.value),false):{pixels:values,changed:false};
    return {pixels:merged.pixels,cols,rows,imageName:source.imageName,merged:merged.changed,adaptive:!pixelPerfect&&els.adaptiveCanvas.checked,detail:analysis.detail};
  }

  async function generate() {
    if(!state.image&&!state.batchSources.length)return;
    if(state.batchProcessing)return;
    let sources=state.batchSources.length?state.batchSources:[{image:state.image,imageName:state.imageName,fileName:state.imageName,pixelPerfect:false}];
    if(!state.batchSources.length)state.batchSources=sources;
    state.batchProcessing=true;state.batchResults=[];state.batchIndex=-1;els.generate.disabled=true;
    try{
      for(let i=0;i<sources.length;i++){
        els.status.textContent=`正在处理 ${i+1} / ${sources.length}`;els.generate.querySelector('span').textContent=`处理中 ${i+1} / ${sources.length}`;
        await new Promise(resolve=>requestAnimationFrame(resolve));
        state.batchResults.push(processImageSource(sources[i]));updateBatchUI();
      }
      activateBatchResult(0);els.stage.focus();
      const mergedCount=state.batchResults.filter(item=>item.merged).length;
      toast(sources.length>1?`${sources.length} 张图片处理完成${mergedCount?` · ${mergedCount} 张已合并色块`:''}`:'像素画生成完成');
    }catch(error){toast('批量处理失败，请减少图片数量后重试');}
    finally{state.batchProcessing=false;els.generate.disabled=false;els.generate.querySelector('span').textContent=sources.length>1?`重新生成全部 ${sources.length} 张`:'重新生成';}
  }

  function makeDemo() {
    const c = document.createElement('canvas'); c.width = 520; c.height = 390;
    const cctx = c.getContext('2d');
    cctx.fillStyle = '#f7f6f1'; cctx.fillRect(0,0,c.width,c.height);
    cctx.fillStyle = '#111';
    cctx.fillRect(140,55,240,30); cctx.fillRect(110,85,300,30);
    cctx.fillRect(80,115,80,150); cctx.fillRect(360,115,80,150);
    cctx.fillStyle = '#777'; cctx.fillRect(160,115,200,180);
    cctx.fillStyle = '#eee'; cctx.fillRect(195,150,45,45); cctx.fillRect(280,150,45,45);
    cctx.fillStyle = '#111'; cctx.fillRect(205,160,25,25); cctx.fillRect(290,160,25,25);
    cctx.fillRect(215,235,90,20); cctx.fillRect(235,255,50,20);
    const img = new Image();
    img.onload = () => { state.image = img; state.imageName = 'mono-pixel-demo'; state.batchSources=[{image:img,imageName:'mono-pixel-demo',fileName:'mono-pixel-demo.png',pixelPerfect:false}];state.batchResults=[];state.batchIndex=0;els.uploadLabel.textContent = '示例：像素机器人'; updateSizePreview();updateBatchUI();generate(); };
    img.src = c.toDataURL();
  }

  function fitCell() {
    const rect = els.stage.getBoundingClientRect();
    const availableW = Math.max(100, rect.width - 100);
    const availableH = Math.max(100, rect.height - 100);
    state.cell = clamp(Math.floor(Math.min(availableW/state.cols, availableH/state.rows)), 4, 24);
  }

  function draw() {
    if (!state.pixels.length) return;
    const cell = Math.max(2, Math.round(state.cell * state.zoom));
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const cssW = state.cols * cell, cssH = state.rows * cell;
    els.canvas.width = cssW * ratio; els.canvas.height = cssH * ratio;
    els.canvas.style.width = `${cssW}px`; els.canvas.style.height = `${cssH}px`;
    ctx.setTransform(ratio,0,0,ratio,0,0);
    ctx.clearRect(0,0,cssW,cssH);

    for (let y=0; y<state.rows; y++) for (let x=0; x<state.cols; x++) {
      const value = state.pixels[y*state.cols+x];
      if (value === null) {
        ctx.fillStyle = (x+y)%2 ? '#dedbd2' : '#f5f3ed';
      } else ctx.fillStyle = `rgb(${value},${value},${value})`;
      ctx.fillRect(x*cell,y*cell,cell,cell);
      if (cell >= 7) {
        ctx.strokeStyle = value === null ? 'rgba(17,17,15,.055)' : 'rgba(255,255,255,.18)';
        ctx.lineWidth = 1;
        ctx.strokeRect(x*cell+.5,y*cell+.5,cell-1,cell-1);
      }
    }
    if(state.tool==='select'&&state.selectionStart&&state.selectionEnd){
      const x1=Math.min(state.selectionStart.x,state.selectionEnd.x),y1=Math.min(state.selectionStart.y,state.selectionEnd.y),x2=Math.max(state.selectionStart.x,state.selectionEnd.x),y2=Math.max(state.selectionStart.y,state.selectionEnd.y);
      ctx.fillStyle='rgba(216,255,57,.22)';ctx.fillRect(x1*cell,y1*cell,(x2-x1+1)*cell,(y2-y1+1)*cell);
      ctx.strokeStyle='#111';ctx.lineWidth=2;ctx.setLineDash([Math.max(3,cell*.35),Math.max(2,cell*.2)]);ctx.strokeRect(x1*cell+1,y1*cell+1,(x2-x1+1)*cell-2,(y2-y1+1)*cell-2);ctx.setLineDash([]);
      const measurement=selectionDimensions(state.selectionStart,state.selectionEnd),label=`${measurement.width} × ${measurement.height} PX`,labelHeight=22;
      ctx.font=`800 ${clamp(Math.round(cell*.68),10,14)}px ui-monospace, monospace`;ctx.textBaseline='middle';
      const labelWidth=Math.ceil(ctx.measureText(label).width)+14;
      const labelX=clamp(x1*cell,2,Math.max(2,cssW-labelWidth-2));
      let labelY=y1*cell-labelHeight-4;if(labelY<2)labelY=Math.min(cssH-labelHeight-2,(y2+1)*cell+4);
      ctx.fillStyle='#111';ctx.fillRect(labelX,labelY,labelWidth,labelHeight);ctx.fillStyle='#d8ff39';ctx.fillText(label,labelX+7,labelY+labelHeight/2);
    }else if (document.activeElement === els.stage || document.activeElement === els.canvas) {
      const radius=['brush','eraser'].includes(state.tool)?Math.floor(state.brushSize/2):0;
      const x1=clamp(state.cursor.x-radius,0,state.cols-1),y1=clamp(state.cursor.y-radius,0,state.rows-1),x2=clamp(state.cursor.x+radius,0,state.cols-1),y2=clamp(state.cursor.y+radius,0,state.rows-1);
      ctx.strokeStyle = '#d8ff39'; ctx.lineWidth = Math.max(2, cell*.12);
      ctx.strokeRect(x1*cell+1,y1*cell+1,(x2-x1+1)*cell-2,(y2-y1+1)*cell-2);
      ctx.strokeStyle = '#111'; ctx.lineWidth = 1;
      ctx.strokeRect(x1*cell-.5,y1*cell-.5,(x2-x1+1)*cell+1,(y2-y1+1)*cell+1);
      if (state.symmetry && ['brush','eraser'].includes(state.tool)) {
        const mx1=state.cols-1-x2,mx2=state.cols-1-x1;
        if(mx1!==x1||mx2!==x2){ctx.strokeStyle='rgba(216,255,57,.55)';ctx.lineWidth=Math.max(2,cell*.12);ctx.strokeRect(mx1*cell+1,y1*cell+1,(mx2-mx1+1)*cell-2,(y2-y1+1)*cell-2);}
      }
    }
    els.zoomOutText.textContent = `${Math.round(state.zoom*100)}%`;
    els.dims.textContent = `${state.cols} × ${state.rows} PX`;
    const count = state.pixels.reduce((n,v) => n + (v !== null), 0);
    els.count.textContent = `${count.toLocaleString()} PIXELS`;
    updateSelectionReadout();
    syncCurrentBatch();
    scheduleProjectSave();
  }

  function captureState() {
    return { pixels:state.pixels.slice(), cols:state.cols, rows:state.rows, cursor:{...state.cursor} };
  }
  function restoreState(saved) {
    state.pixels=saved.pixels; state.cols=saved.cols; state.rows=saved.rows; state.cursor={...saved.cursor};
    els.size.textContent=`${state.cols} × ${state.rows}`; fitCell(); draw();
  }
  function snapshot() {
    if (!state.pixels.length) return;
    state.history.push(captureState());
    if (state.history.length > 80) state.history.shift();
    state.future = [];
    updateHistoryUI();
  }
  function updateHistoryUI() { els.undo.disabled = !state.history.length; els.redo.disabled = !state.future.length; }
  function undo() {
    if (!state.history.length) return;
    state.future.push(captureState()); restoreState(state.history.pop()); updateHistoryUI();
  }
  function redo() {
    if (!state.future.length) return;
    state.history.push(captureState()); restoreState(state.future.pop()); updateHistoryUI();
  }

  function openExpandDialog() {
    if(!state.pixels.length) return;
    els.dialogDims.textContent=`${state.cols} × ${state.rows}`;
    els.expandDialog.showModal();
  }
  function expandCanvas() {
    const top=clamp(Number(els.expandTop.value)||0,0,128), right=clamp(Number(els.expandRight.value)||0,0,128);
    const bottom=clamp(Number(els.expandBottom.value)||0,0,128), left=clamp(Number(els.expandLeft.value)||0,0,128);
    if(!(top+right+bottom+left)){toast('请输入要增加的透明格数');return false;}
    const newCols=state.cols+left+right, newRows=state.rows+top+bottom;
    if(newCols>640||newRows>640){toast('扩展后的画板单边不能超过 640 格');return false;}
    snapshot();
    const expanded=new Array(newCols*newRows).fill(null);
    for(let y=0;y<state.rows;y++) for(let x=0;x<state.cols;x++) expanded[(y+top)*newCols+x+left]=state.pixels[y*state.cols+x];
    state.pixels=expanded; state.cols=newCols; state.rows=newRows;
    state.cursor={x:state.cursor.x+left,y:state.cursor.y+top};
    els.size.textContent=`${state.cols} × ${state.rows}`; fitCell(); updateHistoryUI(); draw();
    toast(`画板已扩展至 ${state.cols} × ${state.rows}`); return true;
  }

  function getBounds() {
    let minX=state.cols, minY=state.rows, maxX=-1, maxY=-1;
    for(let y=0;y<state.rows;y++) for(let x=0;x<state.cols;x++){
      if(state.pixels[y*state.cols+x]===null) continue;
      if(x<minX)minX=x; if(x>maxX)maxX=x; if(y<minY)minY=y; if(y>maxY)maxY=y;
    }
    return maxX<0?null:{minX,maxX,minY,maxY};
  }

  function centerContent() {
    if(!state.pixels.length) return;
    const b=getBounds();
    if(!b) return toast('画板上没有图案，无法居中');
    const w=b.maxX-b.minX+1, h=b.maxY-b.minY+1;
    const targetX=Math.round((state.cols-w)/2);
    const targetY=Math.round((state.rows-h)/2);
    const dx=targetX-b.minX, dy=targetY-b.minY;
    if(dx===0&&dy===0) return toast('图案已经在画板中央');
    const next=new Array(state.cols*state.rows).fill(null);
    for(let y=0;y<state.rows;y++) for(let x=0;x<state.cols;x++){
      const v=state.pixels[y*state.cols+x]; if(v===null) continue;
      const nx=x+dx, ny=y+dy;
      if(nx<0||ny<0||nx>=state.cols||ny>=state.rows) continue;
      next[ny*state.cols+nx]=v;
    }
    snapshot();
    state.pixels=next;
    state.cursor={x:clamp(state.cursor.x+dx,0,state.cols-1),y:clamp(state.cursor.y+dy,0,state.rows-1)};
    draw();
    toast('图案已移至画板中央');
  }

  function mirrorRightFromLeft() {
    if(!state.pixels.length) return;
    const result=new Array(state.cols*state.rows).fill(null);
    const mid=Math.floor(state.cols/2);
    for(let y=0;y<state.rows;y++){
      for(let x=0;x<mid;x++) result[y*state.cols+x]=state.pixels[y*state.cols+x];
      if(state.cols%2===1) result[y*state.cols+mid]=state.pixels[y*state.cols+mid];
    }
    for(let x=0;x<mid;x++){
      const mx=state.cols-1-x;
      for(let y=0;y<state.rows;y++) result[y*state.cols+mx]=result[y*state.cols+x];
    }
    if(samePixels(result,state.pixels)) return toast('右侧已经与左侧对称');
    snapshot(); state.pixels=result; draw();
    toast('已删去右侧内容，并以左侧为基准镜像对称');
  }

  function editPixel(x, y, tool = state.tool, shouldSnapshot = false) {
    if (x<0 || y<0 || x>=state.cols || y>=state.rows) return false;
    if (tool === 'replace') return replaceColorAt(x, y, shouldSnapshot);
    const pos=y*state.cols+x;
    if (tool === 'picker') { if (state.pixels[pos] !== null) setColor(state.pixels[pos]); return false; }
    const next=tool==='eraser'?null:state.color,radius=Math.floor(state.brushSize/2),targets=new Set();
    for(let dy=-radius;dy<=radius;dy++)for(let dx=-radius;dx<=radius;dx++){
      const px=x+dx,py=y+dy;if(px<0||py<0||px>=state.cols||py>=state.rows)continue;
      targets.add(py*state.cols+px);
      if(state.symmetry){const mx=state.cols-1-px;if(mx>=0&&mx<state.cols)targets.add(py*state.cols+mx);}
    }
    const changed=[...targets].some(index=>state.pixels[index]!==next);
    if(!changed)return false;
    if (shouldSnapshot) snapshot();
    targets.forEach(index=>state.pixels[index]=next);
    draw(); return true;
  }

  function replaceColorAt(x, y, shouldSnapshot = false) {
    if (x<0 || y<0 || x>=state.cols || y>=state.rows) return false;
    const pos = y*state.cols+x;
    const source = state.pixels[pos];
    if (source === null) { toast('透明区域不能替换颜色'); return false; }
    if (source === state.color) return false;
    const targets = [];
    for (let i=0;i<state.pixels.length;i++) if (state.pixels[i] === source) targets.push(i);
    if (!targets.length) return false;
    if (shouldSnapshot) snapshot();
    targets.forEach(i => state.pixels[i] = state.color);
    draw();
    toast(`已将 ${targets.length} 个同色像素替换为当前颜色`);
    return true;
  }

  function pointerCell(event) {
    const rect = els.canvas.getBoundingClientRect();
    return { x: clamp(Math.floor((event.clientX-rect.left)/rect.width*state.cols),0,state.cols-1), y: clamp(Math.floor((event.clientY-rect.top)/rect.height*state.rows),0,state.rows-1) };
  }

  function selectionDimensions(start, end) {
    if(!start||!end)return null;
    return {width:Math.abs(end.x-start.x)+1,height:Math.abs(end.y-start.y)+1};
  }

  function updateSelectionReadout() {
    const live=selectionDimensions(state.selectionStart,state.selectionEnd),size=live||state.lastSelectionSize;
    els.selectionSize.textContent=size?`框选 ${size.width} × ${size.height} PX · 导出 ${size.width*16} × ${size.height*16} PX`:'框选 — × — PX';
    els.selectionSize.classList.toggle('active',Boolean(live));
  }

  function deleteSelection() {
    if(!state.selectionStart||!state.selectionEnd)return false;
    const x1=Math.min(state.selectionStart.x,state.selectionEnd.x),y1=Math.min(state.selectionStart.y,state.selectionEnd.y),x2=Math.max(state.selectionStart.x,state.selectionEnd.x),y2=Math.max(state.selectionStart.y,state.selectionEnd.y);
    const measurement=selectionDimensions(state.selectionStart,state.selectionEnd);state.lastSelectionSize=measurement;
    const targets=[];for(let y=y1;y<=y2;y++)for(let x=x1;x<=x2;x++){const pos=y*state.cols+x;if(state.pixels[pos]!==null)targets.push(pos);}
    state.selectionStart=null;state.selectionEnd=null;
    if(!targets.length){draw();toast(`${measurement.width} × ${measurement.height} PX 选区内没有可删除像素`);return false;}
    snapshot();targets.forEach(pos=>state.pixels[pos]=null);draw();toast(`已删除 ${measurement.width} × ${measurement.height} PX 选区内 ${targets.length} 个像素`);return true;
  }

  function setTool(tool) {
    state.tool = tool;
    if(tool!=='select'){state.selectionStart=null;state.selectionEnd=null;}
    $$('.tool').forEach(b => b.classList.toggle('active', b.dataset.tool === tool));
    els.brushSizeControl.classList.toggle('inactive',!['brush','eraser'].includes(tool));
    toast(tool === 'brush' ? `画笔：当前 ${state.brushSize}×${state.brushSize}` : tool === 'eraser' ? `擦除：当前 ${state.brushSize}×${state.brushSize}` : tool === 'replace' ? '替换：点击像素，将图中所有同色像素换成当前颜色' : tool === 'select' ? '框选删除：拖动框住需要清除的区域' : '取色：点击像素获取灰阶');
    if(state.pixels.length)draw();
  }
  function setBrushSize(value,notify=true) {
    let size=clamp(Math.round(Number(value)||1),1,15);if(size%2===0)size+=size>state.brushSize?1:-1;size=clamp(size,1,15);
    state.brushSize=size;els.brushSizeOut.textContent=`${size}×${size}`;els.brushSizeDown.disabled=size<=1;els.brushSizeUp.disabled=size>=15;
    if(notify)toast(`笔刷尺寸：${size}×${size}`);if(state.pixels.length)draw();
  }
  function toggleSymmetry() {
    state.symmetry = !state.symmetry;
    els.symmetryBtn.classList.toggle('active', state.symmetry);
    els.symmetryBtn.setAttribute('aria-pressed', String(state.symmetry));
    toast(state.symmetry ? '左右对称已开启：笔触自动左右镜像' : '左右对称已关闭');
    draw();
  }
  function setColor(value) {
    state.color = Number(value);
    $$('.swatch').forEach(b => b.classList.toggle('active', Number(b.dataset.color) === state.color));
    if (state.tool === 'picker') setTool('brush');
  }

  function keepOuterOutline() {
    if (!state.pixels.length) return;
    const w = state.cols, h = state.rows, pw = w+2, ph = h+2;
    const outside = new Uint8Array(pw*ph);
    const queue = [[0,0]]; outside[0] = 1;
    for (let qi=0; qi<queue.length; qi++) {
      const [x,y] = queue[qi];
      for (const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1]]) {
        const nx=x+dx, ny=y+dy;
        if (nx<0||ny<0||nx>=pw||ny>=ph||outside[ny*pw+nx]) continue;
        const gx=nx-1, gy=ny-1;
        const transparent = gx<0||gy<0||gx>=w||gy>=h||state.pixels[gy*w+gx]===null;
        if (transparent) { outside[ny*pw+nx]=1; queue.push([nx,ny]); }
      }
    }
    const result = new Array(w*h).fill(null);
    for (let y=0;y<h;y++) for (let x=0;x<w;x++) {
      const pos=y*w+x;
      if (state.pixels[pos]===null) continue;
      let edge=false;
      for (const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,-1],[1,-1],[-1,1]]) {
        const px=x+dx+1, py=y+dy+1;
        if (px<0||py<0||px>=pw||py>=ph||outside[py*pw+px]) { edge=true; break; }
      }
      if (edge) result[pos]=0;
    }
    if (samePixels(result,state.pixels)) return toast('当前已经是外轮廓');
    snapshot(); state.pixels=result; draw(); toast('已只保留最外层轮廓');
  }

  function createExportBlob(result={pixels:state.pixels,cols:state.cols,rows:state.rows}) {
    if (!result.pixels.length) return;
    const scale = 16;
    const out = document.createElement('canvas'); out.width=result.cols*scale; out.height=result.rows*scale;
    const outCtx=out.getContext('2d'); outCtx.clearRect(0,0,out.width,out.height);
    result.pixels.forEach((v,i) => {
      if (v===null) return;
      outCtx.fillStyle=`rgb(${v},${v},${v})`;
      outCtx.fillRect((i%result.cols)*scale,Math.floor(i/result.cols)*scale,scale,scale);
    });
    return new Promise(resolve=>out.toBlob(resolve,'image/png'));
  }

  function exportName(name){const safe=(name||'mono-pixel').replace(/[<>:"/\\|?*\x00-\x1F]/g,'-').replace(/-transparent$/i,'');return `${safe}-transparent.png`;}

  async function exportPNG() {
    if (!state.pixels.length) return;
    syncCurrentBatch();
    const filename=exportName(state.imageName);
    if('showSaveFilePicker' in window){
      let handle;
      try{
        handle=await window.showSaveFilePicker({suggestedName:filename,types:[{description:'透明背景 PNG 图片',accept:{'image/png':['.png']}}]});
      }catch(error){ if(error.name!=='AbortError')toast('无法打开保存窗口'); return; }
      try{
        const blob=await createExportBlob(); const writable=await handle.createWritable();
        await writable.write(blob); await writable.close(); toast('PNG 已安全保存，可以直接打开');
      }catch(error){ toast('保存失败，请重新选择位置'); }
      return;
    }
    const blob=await createExportBlob();
    const a=document.createElement('a'); a.href=URL.createObjectURL(blob); a.download=filename; a.click();
    setTimeout(()=>URL.revokeObjectURL(a.href),1000);
    toast('已导出；若被 Windows 阻止，请在文件属性中解除锁定');
  }

  async function importIntoAssembler() {
    if (!state.pixels.length) return;
    syncCurrentBatch();
    const blob = await createExportBlob();
    if (!blob) return toast('无法生成要导入的透明 PNG');
    window.parent.postMessage({
      type: 'mono-pixel:import',
      name: exportName(state.imageName),
      blob,
      logicalWidth: state.cols,
      logicalHeight: state.rows,
      cellSize: 16,
      replaceAssetId: assemblySourceAssetId
    }, '*');
    toast('已发送到 Ink Attack 拼装台');
  }

  window.addEventListener('message',async event=>{
    const payload=event.data;
    if(!payload||payload.type!=='ink-assembly:edit'||!(payload.blob instanceof Blob))return;
    const safeName=(payload.name||'assembly-part.png').replace(/[<>:"/\\|?*\x00-\x1F]/g,'-');
    const file=new File([payload.blob],safeName,{type:payload.blob.type||'image/png'});
    await loadFiles([file],true,payload.sourceAssetId);
    toast('已从拼装台载入选中部件；完成后点击“导入拼装台”回写');
  });

  async function exportAllPNG() {
    syncCurrentBatch();
    if(state.batchResults.length<=1)return exportPNG();
    if('showDirectoryPicker' in window){
      let directory;
      try{directory=await window.showDirectoryPicker({mode:'readwrite'});}catch(error){if(error.name!=='AbortError')toast('无法打开文件夹选择器');return;}
      try{
        for(let i=0;i<state.batchResults.length;i++){
          const result=state.batchResults[i],handle=await directory.getFileHandle(exportName(result.imageName),{create:true}),writable=await handle.createWritable();
          els.status.textContent=`正在导出 ${i+1} / ${state.batchResults.length}`;await writable.write(await createExportBlob(result));await writable.close();
        }
        els.status.textContent='编辑中';toast(`已安全导出 ${state.batchResults.length} 张透明 PNG`);
      }catch(error){toast('批量导出中断，请检查文件夹写入权限');}
      return;
    }
    for(const result of state.batchResults){const blob=await createExportBlob(result),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=exportName(result.imageName);a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1500);await new Promise(resolve=>setTimeout(resolve,180));}
    toast(`已请求下载 ${state.batchResults.length} 张图片`);
  }

  els.fileInput.addEventListener('change', e => loadFiles(e.target.files));
  els.pixelArtInput.addEventListener('change', e => loadFiles(e.target.files,true));
  ['dragenter','dragover'].forEach(type => els.dropzone.addEventListener(type,e=>{e.preventDefault();els.dropzone.classList.add('dragging');}));
  ['dragleave','drop'].forEach(type => els.dropzone.addEventListener(type,e=>{e.preventDefault();els.dropzone.classList.remove('dragging');}));
  els.dropzone.addEventListener('drop', e => loadFiles(e.dataTransfer.files));
  els.stage.addEventListener('dragover', e=>e.preventDefault());
  els.stage.addEventListener('drop', e=>{e.preventDefault();loadFiles(e.dataTransfer.files);});
  [els.width,els.height].forEach(input=>{
    input.addEventListener('input',updateSizePreview);
    input.addEventListener('change',()=>{input.value=clamp(Number(input.value)||80,8,256);updateSizePreview();});
  });
  els.contrast.addEventListener('input',()=>els.contrastOut.textContent=`${els.contrast.value>=0?'+':''}${els.contrast.value}`);
  els.threshold.addEventListener('input',()=>els.thresholdOut.textContent=els.threshold.value);
  els.mergeStrength.addEventListener('input',()=>els.mergeStrengthOut.textContent=els.mergeStrength.value);
  els.autoMerge.addEventListener('change',()=>els.mergeStrengthRow.classList.toggle('disabled',!els.autoMerge.checked));
  els.sidebar.addEventListener('wheel',routeSidebarWheel,{passive:false});
  els.adaptiveCanvas.addEventListener('change',()=>els.adaptiveCanvas.closest('.setting-group').classList.toggle('manual-disabled',els.adaptiveCanvas.checked));
  $$('.segmented button').forEach(btn=>btn.addEventListener('click',()=>{
    state.levels=Number(btn.dataset.levels); $$('.segmented button').forEach(b=>b.classList.toggle('active',b===btn)); els.toneOut.textContent=`${state.levels} 阶`;
  }));
  $$('.tool').forEach(btn=>btn.addEventListener('click',()=>setTool(btn.dataset.tool)));
  $$('.swatch').forEach(btn=>btn.addEventListener('click',()=>setColor(btn.dataset.color)));
  els.symmetryBtn.addEventListener('click',toggleSymmetry);
  els.generate.addEventListener('click',generate); els.demo.addEventListener('click',makeDemo);
  els.undo.addEventListener('click',undo); els.redo.addEventListener('click',redo); els.outline.addEventListener('click',keepOuterOutline); els.merge.addEventListener('click',()=>applyBlockMerge(true));
  els.expand.addEventListener('click',openExpandDialog);
  els.centerBtn.addEventListener('click',centerContent);
  els.mirrorRightBtn.addEventListener('click',mirrorRightFromLeft);
  els.expandForm.addEventListener('submit',e=>{e.preventDefault();if(expandCanvas())els.expandDialog.close();});
  $$('[data-close-dialog]').forEach(btn=>btn.addEventListener('click',()=>els.expandDialog.close()));
  els.exportTop.addEventListener('click',exportAllPNG);
  els.importAssembler.addEventListener('click',importIntoAssembler);
  els.exportFloating.addEventListener('click',exportPNG);
  els.brushSizeDown.addEventListener('click',()=>setBrushSize(state.brushSize-2));
  els.brushSizeUp.addEventListener('click',()=>setBrushSize(state.brushSize+2));
  els.clearBatch.addEventListener('click',clearBatch);
  els.batchPrev.addEventListener('click',()=>activateBatchResult(state.batchIndex-1));
  els.batchNext.addEventListener('click',()=>activateBatchResult(state.batchIndex+1));
  els.zoomIn.addEventListener('click',()=>{state.zoom=clamp(state.zoom+.25,.25,4);draw();});
  els.zoomOut.addEventListener('click',()=>{state.zoom=clamp(state.zoom-.25,.25,4);draw();});

  els.canvas.addEventListener('pointerdown',e=>{
    e.preventDefault(); els.stage.focus(); const p=pointerCell(e); state.cursor=p; state.pointerDown=true; state.strokeChanged=false;
    if(state.tool==='select'){state.selectionStart=p;state.selectionEnd=p;draw();els.canvas.setPointerCapture(e.pointerId);return;}
    if(state.tool!=='picker') snapshot();
    state.strokeChanged=editPixel(p.x,p.y)||state.strokeChanged;
    if(state.tool==='picker') draw();
    els.canvas.setPointerCapture(e.pointerId);
  });
  els.canvas.addEventListener('pointermove',e=>{
    if(!state.pointerDown) return; const p=pointerCell(e); state.cursor=p;
    if(state.tool==='select'){state.selectionEnd=p;draw();return;}
    if(state.tool!=='picker') state.strokeChanged=editPixel(p.x,p.y)||state.strokeChanged;
  });
  const pointerUp=()=>{
    if(state.pointerDown&&state.tool==='select'){deleteSelection();state.pointerDown=false;return;}
    if(state.pointerDown&&!state.strokeChanged&&state.tool!=='picker'){state.history.pop();updateHistoryUI();}
    state.pointerDown=false;
  };
  els.canvas.addEventListener('pointerup',pointerUp);
  els.canvas.addEventListener('pointercancel',()=>{state.pointerDown=false;state.selectionStart=null;state.selectionEnd=null;draw();});

  document.addEventListener('keydown', e=>{
    const typing=['INPUT','TEXTAREA'].includes(document.activeElement.tagName);
    if(typing) return;
    const mod=e.ctrlKey||e.metaKey;
    if(mod&&e.key.toLowerCase()==='z'){e.preventDefault();e.shiftKey?redo():undo();return;}
    if(mod&&e.key.toLowerCase()==='y'){e.preventDefault();redo();return;}
    if(mod&&e.key.toLowerCase()==='e'){e.preventDefault();exportAllPNG();return;}
    if(!state.pixels.length) return;
    const key=e.key.toLowerCase();
    if(key==='b') setTool('brush'); else if(key==='e') setTool('eraser'); else if(key==='i') setTool('picker'); else if(key==='r') setTool('replace'); else if(key==='x') setTool('select'); else if(key==='[') setBrushSize(state.brushSize-2); else if(key===']') setBrushSize(state.brushSize+2); else if(key==='s') toggleSymmetry(); else if(key==='o') keepOuterOutline(); else if(key==='m') applyBlockMerge(true); else if(key==='c') openExpandDialog(); else if(key==='g') centerContent(); else if(key==='f') mirrorRightFromLeft();
    else if(['1','2','3','4'].includes(key)) setColor([0,85,170,255][Number(key)-1]);
    else if(key==='+'||key==='='){state.zoom=clamp(state.zoom+.25,.25,4);draw();}
    else if(key==='-'){state.zoom=clamp(state.zoom-.25,.25,4);draw();}
    else if(['arrowup','arrowdown','arrowleft','arrowright'].includes(key)){
      e.preventDefault();
      if(key==='arrowup')state.cursor.y=clamp(state.cursor.y-1,0,state.rows-1);
      if(key==='arrowdown')state.cursor.y=clamp(state.cursor.y+1,0,state.rows-1);
      if(key==='arrowleft')state.cursor.x=clamp(state.cursor.x-1,0,state.cols-1);
      if(key==='arrowright')state.cursor.x=clamp(state.cursor.x+1,0,state.cols-1);
      draw();
    } else if(key===' '||key==='enter'){e.preventDefault();editPixel(state.cursor.x,state.cursor.y,'brush',true);}
    else if(key==='delete'||key==='backspace'){e.preventDefault();editPixel(state.cursor.x,state.cursor.y,'eraser',true);}
  });
  els.stage.addEventListener('focus',draw); els.stage.addEventListener('blur',draw);
  window.addEventListener('resize',()=>{if(state.pixels.length){fitCell();draw();}});
  const selectionMeasurementSelfTest=selectionDimensions({x:2,y:3},{x:6,y:8});
  document.body.dataset.selectionMeasure=selectionMeasurementSelfTest.width===5&&selectionMeasurementSelfTest.height===6?'pass':'fail';
  updateSizePreview();setBrushSize(1,false);els.adaptiveCanvas.closest('.setting-group').classList.toggle('manual-disabled',els.adaptiveCanvas.checked);updateBatchUI();setReady(false);document.body.dataset.appReady='true';window.parent.postMessage({type:'mono-pixel:ready'},'*');restoreLastProject();
  if(new URLSearchParams(location.search).has('scrolltest'))requestAnimationFrame(runSidebarScrollSelfTest);
})();
