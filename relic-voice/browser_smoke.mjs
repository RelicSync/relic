// Isolated Edge profile + local fixture. No user pages or browser data are read.
import {mkdir, readFile} from 'node:fs/promises';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';

const root = process.cwd();
const profile = path.join(root, 'relic-voice/test-output/browser-' + Date.now());
await mkdir(profile, {recursive:true});
const html = '<title>Relic Voice Compatibility</title><h1>Relic Voice Compatibility</h1><input id="input"><textarea id="textarea"></textarea><div id="editable" contenteditable="true" style="border:1px solid;padding:20px"></div>';
const browser = spawn('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', [
  '--user-data-dir=' + profile, '--remote-debugging-port=0', '--no-first-run',
  '--no-default-browser-check', '--app=data:text/html,' + encodeURIComponent(html)
], {windowsHide:true, stdio:'ignore'});
let socket, closeBrowser;
try {
  let port;
  for(let i=0;i<80;i++) {
    try { port=(await readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]; break; } catch {}
    await new Promise(r=>setTimeout(r,250));
  }
  if(!port)throw Error('Isolated Edge did not start');
  let tab;
  for(let i=0;i<40;i++) {
    const tabs=await (await fetch('http://127.0.0.1:'+port+'/json/list')).json();
    tab=tabs.find(t=>t.title==='Relic Voice Compatibility');
    if(tab)break;
    await new Promise(r=>setTimeout(r,250));
  }
  if(!tab)throw Error('Fixture tab not found');
  socket=new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  let serial=0;const pending=new Map();
  socket.onmessage=e=>{const m=JSON.parse(e.data);if(pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);}};
  function call(method,params={}) {
    const id=++serial;
    return new Promise((resolve,reject)=>{
      const timeout=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout '+method));},5000);
      pending.set(id,{resolve:v=>{clearTimeout(timeout);resolve(v);},reject:e=>{clearTimeout(timeout);reject(e);}});
      socket.send(JSON.stringify({id,method,params}));
    });
  }
  closeBrowser = () => call('Browser.close');
  const spoken='Ask Claude about my tennis shoes. 42';
  const cases=[
    {name:'empty',text:'',start:0,end:0,prefix:''},
    {name:'existing sentence',text:'Existing.',start:9,end:9,prefix:' '},
    {name:'existing space',text:'Existing. ',start:10,end:10,prefix:''},
    {name:'nonbreaking space',text:'Existing.\u00a0',start:10,end:10,prefix:''},
    {name:'start of field',text:'Old',start:0,end:0,prefix:''},
    {name:'replace selection',text:'Old',start:0,end:3,prefix:''},
    {name:'replace a word',text:'Keep old ending',start:5,end:8,prefix:''},
  ];
  for(const field of ['input','textarea','editable']) for(const scenario of cases) {
    await call('Runtime.evaluate',{expression:`(() => {
      const el=document.getElementById(${JSON.stringify(field)});
      const text=${JSON.stringify(scenario.text)};
      if(el.isContentEditable) {
        el.textContent=text; el.focus();
        const range=document.createRange();
        if(el.firstChild) {range.setStart(el.firstChild,${scenario.start}); range.setEnd(el.firstChild,${scenario.end});}
        else {range.selectNodeContents(el);range.collapse(true);}
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
      } else {el.value=text;el.focus();el.setSelectionRange(${scenario.start},${scenario.end});}
    })()`});
    await call('Page.bringToFront');
    await new Promise(r=>setTimeout(r,100));
    const executable=path.join(root,'app/build/windows/x64/voice-tests/Release/voice_native_test.exe');
    const env={...process.env,PATH:path.join(root,'app/build/windows/x64/runner/Release')+';'+process.env.PATH};
    const result=spawnSync(executable,['--browser-test'],{env,windowsHide:true,encoding:'utf8',timeout:10000});
    if(result.status!==0)throw Error('Native insertion failed '+result.status+' '+result.stdout+' '+result.stderr);
    await new Promise(r=>setTimeout(r,200));
    const value=await call('Runtime.evaluate',{expression:'document.getElementById('+JSON.stringify(field)+').'+(field==='editable'?'innerText':'value'),returnByValue:true});
    const expected=scenario.text.slice(0,scenario.start)+scenario.prefix+spoken+scenario.text.slice(scenario.end);
    // Chromium may preserve an editable's leading/trailing spaces as NBSP.
    if(value.result.value.replaceAll('\u00a0',' ')!==expected.replaceAll('\u00a0',' '))throw Error('Text mismatch in '+field+' / '+scenario.name+': '+JSON.stringify(value.result.value));
    console.log('Edge '+field+' / '+scenario.name+': correct spacing, clipboard unchanged');
  }
  await call('Browser.close').catch(()=>{});
} finally {
  await closeBrowser?.().catch(()=>{});
  socket?.close();
  // This PID was created above with its own temporary profile.
  if(browser.exitCode===null)browser.kill();
}
