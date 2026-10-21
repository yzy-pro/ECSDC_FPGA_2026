// Numerical mesh study only: current exact Q14/Q18 projector is the reference.
// No production RTL is changed. Regular destination grid nodes may extend
// just outside the output raster to keep constant power-of-two interpolation.
using System;
using System.Collections.Generic;
using System.Globalization;

public static class MeshAudit {
    const int W=1920,H=1080;
    const long FX=12262554,FY=12256498,CX=15481296,CY=8558941;
    static readonly int[] Sin={0,286,572,857,1143,1428,1713,1997,2280,2563,2845,3126,3406,3686,3964,4240,4516};
    static readonly int[] Cos={16384,16382,16374,16362,16344,16322,16294,16262,16225,16182,16135,16083,16026,15964,15897,15826,15749};
    struct P { public int U,V; public bool Valid; }
    static int Trig(int q,bool cosine) {
        int d=(Math.Abs(q)*29335)>>10,f=d&1023;d>>=10;
        int[] t=cosine?Cos:Sin;
        int r=t[d]+(((t[d+1]-t[d])*f)>>10);
        return !cosine&&q<0?-r:r;
    }
    static P Project(int x,int y,long cy,long sy,long cp,long sp) {
        long xn=(((x+1)*16384L-CX)*((68719476736L+FX/2)/FX))>>18;
        long yn=(((y+1)*16384L-CY)*((68719476736L+FY/2)/FY))>>18;
        long xx=((cy*xn)>>14)+(sy<<4),zz=(cy<<4)-((sy*xn)>>14);
        long yy=((cp*yn)>>14)-((sp*zz)>>14),z=((sp*yn)>>14)+((cp*zz)>>14);
        if(z<=1024 || Math.Abs(xx)>=z*2 || Math.Abs(yy)>=z*2) return new P();
        long rx=(xx<<18)/z,ry=(yy<<18)/z;
        long r2=(rx*rx+ry*ry)>>18,r4=(r2*r2)>>18;
        if(r2>600000) return new P();
        long scale=16384+((162*r2)>>18)+((-711*r4)>>18);
        long xd=(rx*scale)>>14,yd=(ry*scale)>>14;
        long u=((xd*FX)>>18)+CX-16384,v=((yd*FY)>>18)+CY-16384;
        if(u<0 || u>=(W-1)*16384 || v<0 || v>=(H-1)*16384) return new P();
        return new P { U=(int)u,V=(int)v,Valid=true };
    }
    static void Pose(int yaw,int pitch) {
        long cy=Trig(yaw,true),sy=Trig(yaw,false),cp=Trig(pitch,true),sp=Trig(pitch,false);
        var reference=new P[W*H];int valid=0;
        for(int y=0;y<H;y++) for(int x=0;x<W;x++) {
            P p=Project(x,y,cy,sy,cp,sp);reference[y*W+x]=p;if(p.Valid)valid++;
        }
        foreach(int step in new int[]{8,16,32,64}) {
            int cols=(W+step-1)/step,rows=(H+step-1)/step;
            var nodes=new P[(cols+1)*(rows+1)];int nodeValid=0;
            for(int y=0;y<=rows;y++) for(int x=0;x<=cols;x++) {
                P p=Project(x*step,y*step,cy,sy,cp,sp);nodes[y*(cols+1)+x]=p;if(p.Valid)nodeValid++;
            }
            int interpPixels=0,fallbackPixels=0,allInvalidPixels=0,falseValid=0,holePixels=0,wrongNearest=0,aboveQuarter=0,aboveHalf=0,aboveOne=0;
            double sum2=0,max=0,maxComponent=0;int worstX=0,worstY=0;
            var errors=new List<double>(W*H);
            for(int gy=0;gy<rows;gy++) for(int gx=0;gx<cols;gx++) {
                P p00=nodes[gy*(cols+1)+gx],p10=nodes[gy*(cols+1)+gx+1];
                P p01=nodes[(gy+1)*(cols+1)+gx],p11=nodes[(gy+1)*(cols+1)+gx+1];
                int nvalid=(p00.Valid?1:0)+(p10.Valid?1:0)+(p01.Valid?1:0)+(p11.Valid?1:0);
                for(int dy=0;dy<step&&gy*step+dy<H;dy++) for(int dx=0;dx<step&&gx*step+dx<W;dx++) {
                    int x=gx*step+dx,y=gy*step+dy;P truth=reference[y*W+x];
                    if(nvalid<4) {
                        fallbackPixels++;
                        if(nvalid==0){allInvalidPixels++;if(truth.Valid)holePixels++;}
                        continue;
                    }
                    interpPixels++;
                    if(!truth.Valid){falseValid++;continue;}
                    long a=(step-dx)*(step-dy),b=dx*(step-dy),c=(step-dx)*dy,d=dx*dy,den=step*step;
                    long u=(a*p00.U+b*p10.U+c*p01.U+d*p11.U+den/2)/den;
                    long v=(a*p00.V+b*p10.V+c*p01.V+d*p11.V+den/2)/den;
                    double ex=(u-truth.U)/16384.0,ey=(v-truth.V)/16384.0,e2=ex*ex+ey*ey,e=Math.Sqrt(e2);
                    if(e>max){max=e;worstX=x;worstY=y;}
                    maxComponent=Math.Max(maxComponent,Math.Max(Math.Abs(ex),Math.Abs(ey)));
                    sum2+=e2;errors.Add(e);
                    if(e>0.25)aboveQuarter++;if(e>0.5)aboveHalf++;if(e>1.0)aboveOne++;
                    if(((u+8192)>>14)!=((truth.U+8192)>>14)||((v+8192)>>14)!=((truth.V+8192)>>14))wrongNearest++;
                }
            }
            errors.Sort();int n=errors.Count;
            Console.WriteLine(String.Format(CultureInfo.InvariantCulture,
                "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11:F6},{12:F6},{13:F6},{14:F6},{15:F6},{16},{17},{18},{19},{20},{21},{22}",
                yaw,pitch,step,nodes.Length,nodeValid,valid,interpPixels,fallbackPixels,allInvalidPixels,falseValid,holePixels,
                Math.Sqrt(sum2/n),errors[(int)((n-1)*0.95)],errors[(int)((n-1)*0.99)],max,maxComponent,
                aboveQuarter,aboveHalf,aboveOne,wrongNearest,worstX,worstY,n));
        }
    }
    public static void Run(){
        Console.WriteLine("yaw_q2048,pitch_q2048,grid_step,node_projections,valid_nodes,exact_valid_pixels,interpolated_pixels,fallback_pixels,all_invalid_corner_pixels,false_valid_interior_pixels,valid_pixels_with_all_invalid_corners,rms_coordinate_error_px,p95_coordinate_error_px,p99_coordinate_error_px,max_coordinate_error_px,max_component_error_px,error_over_025_pixels,error_over_05_pixels,error_over_1_pixels,nearest_address_changed_pixels,worst_error_x,worst_error_y,error_samples");
        int[,] poses={{0,0},{-144,0},{536,0},{-536,0},{0,536},{0,-536},{536,536},{536,-536},{-536,536},{-536,-536}};
        for(int i=0;i<poses.GetLength(0);i++)Pose(poses[i,0],poses[i,1]);
    }
}
