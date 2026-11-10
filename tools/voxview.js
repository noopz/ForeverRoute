// Render a crop of the layered walk map: green = one floor, yellow = 2 floors, magenta = 3+, dark = no floor (wall/steep),
// blue = swim. Optional path (white) from a to b, following the Dijkstra field downhill.
// usage: node voxview.js <terrainDir> <area> <x0,y0,x1,y1 map%> <out.png> [ax,ay bx,by]
const fs=require('fs'), zlib=require('zlib'); const {VoxNav}=require('./voxnav');
const [dir,area,crop,out,A,Bp]=process.argv.slice(2); const nav=new VoxNav(dir,area); const M=nav.meta, B=M.bounds;
const [x0,y0,x1,y1]=crop.split(',').map(Number);
const c0=Math.floor(x0/100*(B.left-B.right)/M.cell), c1=Math.floor(x1/100*(B.left-B.right)/M.cell), r0=Math.floor(y0/100*(B.top-B.bottom)/M.cell), r1=Math.floor(y1/100*(B.top-B.bottom)/M.cell);
const S=2, Wd=(c1-c0)*S, Hd=(r1-r0)*S, img=Buffer.alloc((Wd*3+1)*Hd);
const put=(r,c,rgb)=>{for(let a=0;a<S;a++)for(let b=0;b<S;b++){const rr=(r-r0)*S+a, cc=(c-c0)*S+b; if(rr<0||cc<0||rr>=Hd||cc>=Wd)continue; const o=rr*(Wd*3+1)+1+cc*3; img[o]=rgb[0];img[o+1]=rgb[1];img[o+2]=rgb[2];}};
for(let r=r0;r<r1;r++)for(let c=c0;c<c1;c++){const col=r*nav.W+c, n=nav.cs[col+1]-nav.cs[col]; let rgb=[30,30,30]; if(n===1) rgb=nav.swim[nav.cs[col]]?[40,80,200]:[60,140,60]; else if(n===2) rgb=[230,210,40]; else if(n>2) rgb=[230,40,230]; put(r,c,rgb);}
if(A&&Bp){const P=s=>{const[x,y]=s.split(',').map(Number);return{x,y}}; const r=nav.path(P(A),P(Bp)); console.log('path length',Math.round(r.length),'yd');
 const zs=r.floors.map(f=>nav.z[f]); const zmin=Math.min(...zs), zmax=Math.max(...zs);
 for(const f of r.floors){const col=nav.colOf[f]; const t=(nav.z[f]-zmin)/(zmax-zmin||1); put(Math.floor(col/nav.W),col%nav.W,[0,Math.round(120+135*t),255]);}
 console.log('path z',zmin.toFixed(1),'..',zmax.toFixed(1),'(white = high, red = low)');}
const crcT=new Int32Array(256).map((_,n)=>{let c=n;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;return c;}); const crc=b=>{let c=-1;for(const x of b)c=crcT[(c^x)&255]^(c>>>8);return(c^-1)>>>0;};
const ch=(t,d)=>{const l=Buffer.alloc(4);l.writeUInt32BE(d.length);const td=Buffer.concat([Buffer.from(t),d]);const cb=Buffer.alloc(4);cb.writeUInt32BE(crc(td));return Buffer.concat([l,td,cb]);};
const ih=Buffer.alloc(13);ih.writeUInt32BE(Wd,0);ih.writeUInt32BE(Hd,4);ih[8]=8;ih[9]=2;
fs.writeFileSync(out,Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),ch('IHDR',ih),ch('IDAT',zlib.deflateSync(img)),ch('IEND',Buffer.alloc(0))]));
