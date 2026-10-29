/* SPOTOUT – kleiner QR-Code-Erzeuger (nur Byte-Modus, Version 1–40).
   Eigene Datei statt einer Bibliothek vom CDN: das Profil-Teilen soll
   ohne fremden Server laufen, auch in der App. Aufgebaut nach ISO/IEC
   18004 (Reed-Solomon in GF(256), acht Masken, Strafpunkte), Ablauf wie
   bei Nayukis bekanntem Referenz-Erzeuger.

   window.spotoutQR(text, stufe?, maske?) -> { groesse, dunkel(x,y), maske, version }
   stufe: 'L' | 'M' (Standard) | 'Q' | 'H'; maske nur zum Testen.
   Laeuft auch in node (module.exports), damit es sich pruefen laesst. */
(function(wurzel){
  'use strict';
  // Fehlerkorrektur-Woerter pro Block und Anzahl Bloecke, Index = Version
  var ECC_PRO_BLOCK={
    L:[-1,7,10,15,20,26,18,20,24,30,18,20,24,26,30,22,24,28,30,28,28,28,28,30,30,26,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],
    M:[-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28],
    Q:[-1,13,22,18,26,18,24,18,22,20,24,28,26,24,20,30,24,28,28,26,30,28,30,30,30,30,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],
    H:[-1,17,28,22,16,22,28,26,26,24,28,24,28,22,24,24,30,28,28,26,28,30,24,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30]
  };
  var BLOECKE={
    L:[-1,1,1,1,1,1,2,2,2,2,4,4,4,4,4,6,6,6,6,7,8,8,9,9,10,12,12,12,13,14,15,16,17,18,19,19,20,21,22,24,25],
    M:[-1,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49],
    Q:[-1,1,1,2,2,4,4,6,6,8,8,8,10,12,16,12,17,16,18,21,20,23,23,25,27,29,34,34,35,38,40,43,45,48,51,53,56,59,62,65,68],
    H:[-1,1,1,2,4,4,4,5,6,8,8,11,11,16,16,18,16,19,21,25,25,25,34,30,32,35,37,40,42,45,48,51,54,57,60,63,66,70,74,77,81]
  };
  var FORMAT_BITS={L:1,M:0,Q:3,H:2};

  function bit(x,i){ return ((x>>>i)&1)!==0; }

  function rohModule(ver){
    var r=(16*ver+128)*ver+64;
    if(ver>=2){
      var n=Math.floor(ver/7)+2;
      r-=(25*n-10)*n-55;
      if(ver>=7)r-=36;
    }
    return r;
  }
  function datenWoerter(ver,st){
    return Math.floor(rohModule(ver)/8)-ECC_PRO_BLOCK[st][ver]*BLOECKE[st][ver];
  }

  // Reed-Solomon ueber GF(2^8), Polynom 0x11D
  function mal(x,y){
    var z=0;
    for(var i=7;i>=0;i--){
      z=(z<<1)^((z>>>7)*0x11D);
      z^=((y>>>i)&1)*x;
    }
    return z;
  }
  function teiler(grad){
    var r=[];
    for(var i=0;i<grad-1;i++)r.push(0);
    r.push(1);
    var w=1;
    for(var k=0;k<grad;k++){
      for(var j=0;j<r.length;j++){
        r[j]=mal(r[j],w);
        if(j+1<r.length)r[j]^=r[j+1];
      }
      w=mal(w,0x02);
    }
    return r;
  }
  function rest(daten,t){
    var r=t.map(function(){return 0;});
    daten.forEach(function(b){
      var f=b^r.shift();
      r.push(0);
      t.forEach(function(c,i){ r[i]^=mal(c,f); });
    });
    return r;
  }

  function utf8(text){
    var s=unescape(encodeURIComponent(String(text)));
    var b=[];
    for(var i=0;i<s.length;i++)b.push(s.charCodeAt(i));
    return b;
  }

  function erzeuge(text,stufe,festeMaske){
    var st=FORMAT_BITS.hasOwnProperty(stufe)?stufe:'M';
    var bytes=utf8(text);
    // Kleinste Version, in die es passt
    var ver,zaehlBits;
    for(ver=1;ver<=40;ver++){
      zaehlBits=ver<=9?8:16;
      if(4+zaehlBits+bytes.length*8<=datenWoerter(ver,st)*8)break;
    }
    if(ver>40)throw new Error('Text zu lang fuer einen QR-Code');

    // Bitstrom: Modus Byte (0100), Laenge, Daten, Abschluss, Fuellbytes
    var bits=[];
    function haenge(wert,n){ for(var i=n-1;i>=0;i--)bits.push((wert>>>i)&1); }
    haenge(4,4); haenge(bytes.length,zaehlBits);
    bytes.forEach(function(b){ haenge(b,8); });
    var kap=datenWoerter(ver,st)*8;
    haenge(0,Math.min(4,kap-bits.length));
    haenge(0,(8-bits.length%8)%8);
    for(var pad=0xEC;bits.length<kap;pad^=0xEC^0x11)haenge(pad,8);
    var woerter=[];
    for(var i=0;i<bits.length;i+=8){
      var w=0; for(var j=0;j<8;j++)w=(w<<1)|bits[i+j];
      woerter.push(w);
    }

    // Fehlerkorrektur und Verschraenken der Bloecke
    var nBl=BLOECKE[st][ver], eccLen=ECC_PRO_BLOCK[st][ver];
    var roh=Math.floor(rohModule(ver)/8);
    var kurz=nBl-roh%nBl, kurzLen=Math.floor(roh/nBl);
    var t=teiler(eccLen), bl=[], k=0;
    for(var b=0;b<nBl;b++){
      var len=kurzLen-eccLen+(b<kurz?0:1);
      var dat=woerter.slice(k,k+len); k+=len;
      var ecc=rest(dat,t);
      if(b<kurz)dat.push(0);
      bl.push(dat.concat(ecc));
    }
    var alle=[];
    for(var x=0;x<bl[0].length;x++){
      for(var y=0;y<bl.length;y++){
        if(x!==kurzLen-eccLen||y>=kurz)alle.push(bl[y][x]);
      }
    }

    var n=ver*4+17;
    var mod=[],fest=[];
    for(var r=0;r<n;r++){ mod.push(new Array(n).fill(false)); fest.push(new Array(n).fill(false)); }
    function setze(x,y,d){ mod[y][x]=d; fest[y][x]=true; }

    // Taktlinien
    for(var a=0;a<n;a++){ setze(6,a,a%2===0); setze(a,6,a%2===0); }
    // Suchmuster
    function sucher(cx,cy){
      for(var dy=-4;dy<=4;dy++)for(var dx=-4;dx<=4;dx++){
        var d=Math.max(Math.abs(dx),Math.abs(dy)),xx=cx+dx,yy=cy+dy;
        if(xx>=0&&xx<n&&yy>=0&&yy<n)setze(xx,yy,d!==2&&d!==4);
      }
    }
    sucher(3,3); sucher(n-4,3); sucher(3,n-4);
    // Ausrichtungsmuster
    var pos=[];
    if(ver>1){
      var anz=Math.floor(ver/7)+2;
      var schritt=ver===32?26:Math.ceil((ver*4+4)/(anz*2-2))*2;
      pos=[6];
      for(var p=n-7;pos.length<anz;p-=schritt)pos.splice(1,0,p);
    }
    pos.forEach(function(px,i){
      pos.forEach(function(py,j){
        if((i===0&&j===0)||(i===0&&j===pos.length-1)||(i===pos.length-1&&j===0))return;
        for(var dy=-2;dy<=2;dy++)for(var dx=-2;dx<=2;dx++)
          setze(px+dx,py+dy,Math.max(Math.abs(dx),Math.abs(dy))!==1);
      });
    });
    function formatBits(maske){
      var d=FORMAT_BITS[st]<<3|maske, rr=d;
      for(var i=0;i<10;i++)rr=(rr<<1)^((rr>>>9)*0x537);
      var f=(d<<10|rr)^0x5412;
      for(i=0;i<=5;i++)setze(8,i,bit(f,i));
      setze(8,7,bit(f,6)); setze(8,8,bit(f,7)); setze(7,8,bit(f,8));
      for(i=9;i<15;i++)setze(14-i,8,bit(f,i));
      for(i=0;i<8;i++)setze(n-1-i,8,bit(f,i));
      for(i=8;i<15;i++)setze(8,n-15+i,bit(f,i));
      setze(8,n-8,true);
    }
    formatBits(0);   // Platz reservieren, echte Werte nach der Maskenwahl
    if(ver>=7){
      var vr=ver;
      for(var q=0;q<12;q++)vr=(vr<<1)^((vr>>>11)*0x1F25);
      var vb=ver<<12|vr;
      for(q=0;q<18;q++){
        var aa=n-11+q%3, bb=Math.floor(q/3);
        setze(aa,bb,bit(vb,q)); setze(bb,aa,bit(vb,q));
      }
    }

    // Datenbits im Zickzack von unten rechts
    var ib=0;
    for(var rechts=n-1;rechts>=1;rechts-=2){
      if(rechts===6)rechts=5;
      for(var v=0;v<n;v++){
        for(var jj=0;jj<2;jj++){
          var xx=rechts-jj, hoch=((rechts+1)&2)===0, yy=hoch?n-1-v:v;
          if(!fest[yy][xx]&&ib<alle.length*8){
            mod[yy][xx]=bit(alle[ib>>>3],7-(ib&7));
            ib++;
          }
        }
      }
    }

    function maskiere(m){
      for(var y=0;y<n;y++)for(var x=0;x<n;x++){
        if(fest[y][x])continue;
        var inv;
        switch(m){
          case 0:inv=(x+y)%2===0;break;
          case 1:inv=y%2===0;break;
          case 2:inv=x%3===0;break;
          case 3:inv=(x+y)%3===0;break;
          case 4:inv=(Math.floor(x/3)+Math.floor(y/2))%2===0;break;
          case 5:inv=x*y%2+x*y%3===0;break;
          case 6:inv=(x*y%2+x*y%3)%2===0;break;
          default:inv=((x+y)%2+x*y%3)%2===0;
        }
        if(inv)mod[y][x]=!mod[y][x];
      }
    }
    // Strafpunkte nach Norm (N1–N4), kleinste Summe gewinnt
    function strafe(){
      var s=0,x,y;
      function linie(get){
        var p=0,lauf=1,i;
        for(i=1;i<=n;i++){
          if(i<n&&get(i)===get(i-1))lauf++;
          else{ if(lauf>=5)p+=3+(lauf-5); lauf=1; }
        }
        // 1:1:3:1:1 mit vier hellen Modulen davor oder danach
        // ausserhalb des Codes zaehlt als hell (Ruhezone)
        var hell=function(j){ return j<0||j>=n||!get(j); };
        var m=[1,0,1,1,1,0,1];
        for(i=0;i+7<=n;i++){
          var ok=true,k;
          for(k=0;k<7;k++)if(get(i+k)!==!!m[k]){ok=false;break;}
          if(!ok)continue;
          var vor=true,nach=true;
          for(k=1;k<=4;k++){ if(!hell(i-k))vor=false; if(!hell(i+6+k))nach=false; }
          if(vor||nach)p+=40;
        }
        return p;
      }
      for(y=0;y<n;y++)s+=linie(function(i){return mod[y][i];});
      for(x=0;x<n;x++)s+=linie(function(i){return mod[i][x];});
      for(y=0;y<n-1;y++)for(x=0;x<n-1;x++){
        var c=mod[y][x];
        if(c===mod[y][x+1]&&c===mod[y+1][x]&&c===mod[y+1][x+1])s+=3;
      }
      var dunkel=0;
      for(y=0;y<n;y++)for(x=0;x<n;x++)if(mod[y][x])dunkel++;
      var tot=n*n;
      s+=Math.floor(Math.abs(dunkel*20-tot*10)/tot)*10;
      return s;
    }
    var beste=festeMaske;
    if(beste==null){
      var min=Infinity;
      for(var mm=0;mm<8;mm++){
        maskiere(mm); formatBits(mm);
        var pz=strafe();
        if(pz<min){min=pz;beste=mm;}
        maskiere(mm);   // XOR: zweimal = rueckgaengig
      }
    }
    maskiere(beste); formatBits(beste);
    return {
      groesse:n, version:ver, maske:beste,
      dunkel:function(x,y){ return x>=0&&y>=0&&x<n&&y<n&&mod[y][x]; }
    };
  }

  wurzel.spotoutQR=erzeuge;
  if(typeof module!=='undefined'&&module.exports)module.exports=erzeuge;
})(typeof window!=='undefined'?window:globalThis);
