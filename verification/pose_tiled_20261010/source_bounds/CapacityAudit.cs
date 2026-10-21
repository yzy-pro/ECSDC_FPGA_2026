// Read-only source-cache capacity audit for the current 1920x1080 defaults.
// Sweep: evaluates every output pixel for sampled Q2048 poses, matching the
// integer projector's rounding. This alone is not an exhaustive angle proof.
// Bound: interval arithmetic over all integer poses -536..536 on both axes
// and every output coordinate; includes possible false-positive map pixels.
// Thus an interval capacity bound is conservative for the enumerated domain.
// No HDL simulation or timing claim is made by this program.
using System;

public static class CapacityAudit {
    const long FX=12262554,FY=12256498,CX=15481296,CY=8558941;
    const int W=1920,H=1080,TW=128,TH=32;
    static readonly int[] Sin={0,286,572,857,1143,1428,1713,1997,2280,2563,2845,3126,3406,3686,3964,4240,4516};
    static readonly int[] Cos={16384,16382,16374,16362,16344,16322,16294,16262,16225,16182,16135,16083,16026,15964,15897,15826,15749};
    static readonly long[] X=Norm(W,FX,CX),Y=Norm(H,FY,CY);
    static long[] Norm(int n,long f,long c) {
        var a=new long[n];long inv=(68719476736L+f/2)/f;
        for(int i=0;i<n;i++) a[i]=(((i+1)*16384L-c)*inv)>>18;
        return a;
    }
    static int Trig(int q,bool cosine) {
        int d=(Math.Abs(q)*29335)>>10,f=d&1023;d>>=10;
        int[] t=cosine?Cos:Sin;
        int r=t[d]+(((t[d+1]-t[d])*f)>>10);
        return !cosine&&q<0?-r:r;
    }
    public static string Frame(int ya,int pi) {
        long cy=Trig(ya,true),sy=Trig(ya,false),cp=Trig(pi,true),sp=Trig(pi,false);
        int maximum=0,maxx=0,maxy=0,mwords=0,mrows=0,total=0,commands=0,valid=0;
        for(int y0=0;y0<H;y0+=TH) for(int x0=0;x0<W;x0+=TW) {
            int xmin=W,xmax=-1,ymin=H,ymax=-1;
            for(int y=y0;y<Math.Min(H,y0+TH);y++) for(int x=x0;x<x0+TW;x++) {
                long xx=((cy*X[x])>>14)+(sy<<4),zz=(cy<<4)-((sy*X[x])>>14);
                long yy=((cp*Y[y])>>14)-((sp*zz)>>14),z=((sp*Y[y])>>14)+((cp*zz)>>14);
                if(z<=1024 || Math.Abs(xx)>=z*2 || Math.Abs(yy)>=z*2) continue;
                long rx=(xx<<18)/z,ry=(yy<<18)/z;
                long r2=(rx*rx+ry*ry)>>18,r4=(r2*r2)>>18;
                if(r2>600000) continue;
                long scale=16384+((162*r2)>>18)+((-711*r4)>>18);
                long xd=(rx*scale)>>14,yd=(ry*scale)>>14;
                long u=((xd*FX)>>18)+CX-16384,v=((yd*FY)>>18)+CY-16384;
                if(u<0 || u>=(W-1)*16384 || v<0 || v>=(H-1)*16384) continue;
                int sx=(int)((u+8192)>>14),sv=(int)((v+8192)>>14);valid++;
                xmin=Math.Min(xmin,sx);xmax=Math.Max(xmax,sx);ymin=Math.Min(ymin,sv);ymax=Math.Max(ymax,sv);
            }
            if(xmax<0) continue;
            int words=xmax/16-xmin/16+1,rows=ymax-ymin+1,sz=words*rows;
            total+=sz;commands+=((words+15)/16)*rows;
            if(sz>maximum){maximum=sz;maxx=x0;maxy=y0;mwords=words;mrows=rows;}
        }
        return String.Format("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}",ya,pi,maximum,maxx,maxy,mwords,mrows,total,commands,valid);
    }
    public static void Sweep() {
        int[] angles={-536,-357,-179,0,179,357,536};
        Console.WriteLine("yaw_q2048,pitch_q2048,max_source_beats,tile_x,tile_y,bbox_words,bbox_rows,source_beats,source_commands,valid_pixels");
        foreach(int y in angles) foreach(int p in angles) Console.WriteLine(Frame(y,p));
    }

    struct I {
        public long Lo,Hi;
        public I(long l,long h){Lo=l;Hi=h;}
        public I(long v){Lo=v;Hi=v;}
        public static I operator +(I a,I b){return new I(a.Lo+b.Lo,a.Hi+b.Hi);}
        public static I operator -(I a,I b){return new I(a.Lo-b.Hi,a.Hi-b.Lo);}
        public static I operator *(I a,I b){
            long p=a.Lo*b.Lo,q=a.Lo*b.Hi,r=a.Hi*b.Lo,s=a.Hi*b.Hi;
            return new I(Math.Min(Math.Min(p,q),Math.Min(r,s)),Math.Max(Math.Max(p,q),Math.Max(r,s)));
        }
        public I Shift(int n){return new I(Lo>>n,Hi>>n);}
        public I Square(){return new I(Lo<=0&&Hi>=0?0:Math.Min(Lo*Lo,Hi*Hi),Math.Max(Lo*Lo,Hi*Hi));}
        public I Clip(long l,long h){return new I(Math.Max(l,Lo),Math.Min(h,Hi));}
        public bool Empty {get{return Lo>Hi;}}
        // C# signed division truncates towards zero, matching restoring
        // magnitude division followed by sign application in the RTL.
        public I DivideQ18(I z){
            long p=(Lo<<18)/z.Lo,q=(Lo<<18)/z.Hi,r=(Hi<<18)/z.Lo,s=(Hi<<18)/z.Hi;
            return new I(Math.Min(Math.Min(p,q),Math.Min(r,s)),Math.Max(Math.Max(p,q),Math.Max(r,s)));
        }
    }
    static I TrigBounds(int low,int high,bool cosine){
        long l=32767,h=-32768;
        for(int i=low;i<=high;i++){int t=Trig(i,cosine);l=Math.Min(l,t);h=Math.Max(h,t);}
        return new I(l,h);
    }
    public static void Bound(int poseStep,int pixelStep){
        if(poseStep<1 || pixelStep<1 || TW%pixelStep!=0 || TH%pixelStep!=0)
            throw new ArgumentException("positive poseStep, pixelStep dividing 128 and 32 required");
        int maximum=0,worstYa=0,worstPi=0,worstX=0,worstY=0,worstWords=0,worstRows=0,buckets=0;
        for(int ya=-536;ya<=536;ya+=poseStep) for(int pi=-536;pi<=536;pi+=poseStep){
            int yh=Math.Min(536,ya+poseStep-1),ph=Math.Min(536,pi+poseStep-1);buckets++;
            I cy=TrigBounds(ya,yh,true),sy=TrigBounds(ya,yh,false),cp=TrigBounds(pi,ph,true),sp=TrigBounds(pi,ph,false);
            for(int ty=0;ty<H;ty+=TH) for(int tx=0;tx<W;tx+=TW){
                int xmin=W,xmax=-1,ymin=H,ymax=-1;
                for(int by=ty;by<Math.Min(H,ty+TH);by+=pixelStep) for(int bx=tx;bx<tx+TW;bx+=pixelStep){
                    I xn=new I(X[bx],X[Math.Min(tx+TW-1,bx+pixelStep-1)]);
                    I yn=new I(Y[by],Y[Math.Min(H-1,by+pixelStep-1)]);
                    I xx=(cy*xn).Shift(14)+sy*new I(16),zz=cy*new I(16)-(sy*xn).Shift(14);
                    I yy=(cp*yn).Shift(14)-(sp*zz).Shift(14),z=(sp*yn).Shift(14)+(cp*zz).Shift(14);
                    z=z.Clip(1025,long.MaxValue);if(z.Empty) continue;
                    I rx=xx.DivideQ18(z).Clip(-524287,524287),ry=yy.DivideQ18(z).Clip(-524287,524287);
                    if(rx.Empty||ry.Empty) continue;
                    I r2=(rx.Square()+ry.Square()).Shift(18).Clip(0,600000);if(r2.Empty) continue;
                    I r4=r2.Square().Shift(18);
                    I scale=new I(16384)+(new I(162)*r2).Shift(18)+(new I(-711)*r4).Shift(18);
                    I u=((rx*scale).Shift(14)*new I(FX)).Shift(18)+new I(CX-16384);
                    I v=((ry*scale).Shift(14)*new I(FY)).Shift(18)+new I(CY-16384);
                    u=u.Clip(0,(W-1)*16384-1);v=v.Clip(0,(H-1)*16384-1);if(u.Empty||v.Empty) continue;
                    xmin=Math.Min(xmin,(int)((u.Lo+8192)>>14));xmax=Math.Max(xmax,(int)((u.Hi+8192)>>14));
                    ymin=Math.Min(ymin,(int)((v.Lo+8192)>>14));ymax=Math.Max(ymax,(int)((v.Hi+8192)>>14));
                }
                if(xmax<0)continue;
                int words=xmax/16-xmin/16+1,rows=ymax-ymin+1,size=words*rows;
                if(size>maximum){maximum=size;worstYa=ya;worstPi=pi;worstX=tx;worstY=ty;worstWords=words;worstRows=rows;}
            }
        }
        Console.WriteLine("scope: all integer yaw,pitch in [-536,536], all 1920x1080 output pixels, 128x32 tiles, current default calibration, exact divider, nearest tap");
        Console.WriteLine("method: conservative integer intervals; each pose bucket covers every quantized pose, each pixel cell covers every coordinate; bound may include impossible combinations");
        Console.WriteLine("pose_bucket_step={0} pixel_cell_step={1} pose_buckets={2}",poseStep,pixelStep,buckets);
        Console.WriteLine("max_source_beats_bound={0} source_slot_capacity=2048 bytes_bound={1}",maximum,maximum*32);
        Console.WriteLine("worst_bucket_yaw=[{0},{1}] pitch=[{2},{3}] tile={4},{5} bbox_words_bound={6} bbox_rows_bound={7}",
            worstYa,Math.Min(536,worstYa+poseStep-1),worstPi,Math.Min(536,worstPi+poseStep-1),worstX,worstY,worstWords,worstRows);
        if(maximum>2048) throw new InvalidOperationException("interval bound exceeds capacity; refine partition or increase capacity");
        Console.WriteLine("PASS conservative source-capacity bound (software arithmetic model, not formal RTL equivalence or timing proof)");
    }
}
