# -*- coding: utf-8 -*-
# Fig. 1 (concept), drawn as SVG and converted with cairosvg (pip install cairosvg).
# Colors follow the other figures: purple the analog crossbar, teal the SRAM partition,
# rust the address map, green the digital logic; gold marks the drift-sensitive weights.
# The one bit per weight is shown as given by the address map; the summing block is
# the digital accumulator (in the RTL the 24-bit unit is the combiner and the layer
# accumulator is 32-bit). Writes SVG, PNG and PDF into --out.
# Usage: python3 scripts/fig01_concept.py --out figures
import argparse, os
_ap = argparse.ArgumentParser(); _ap.add_argument("--out", default="figures"); _a = _ap.parse_args()
os.makedirs(_a.out, exist_ok=True)
SUB_I="\u1D62"; SIG="\u03A3"; ARR="\u2192"; AP="\u2248"; MUL=chr(215)
W,H = 1320, 716
P_ANA,P_ANA_D,P_ANA_L = "#8C79C0","#5B4990","#ECE7F6"
G_DIG,G_DIG_D,G_DIG_L = "#5FA77B","#2E7D4F","#E4F1EA"
AMB,AMB_D,AMB_L       = "#E6B422","#8A6A00","#FBF3D5"
TEA,TEA_D,TEA_L       = "#4E98A6","#2A6F7D","#DCEBEE"
RUS,RUS_D,RUS_L       = "#C98A63","#9A4F2A","#F6E6DC"
GRY,GRY_L,INK,RED     = "#7A7A7A","#DCDCDC","#1E1E1E","#C0392B"
RED_L="#FBE9E7"; FONT="Liberation Sans, Arial, Helvetica, sans-serif"
s=[]; add=s.append
add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="{FONT}">')
add(f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>')
add('<defs>')
for nm,col in [("ink",INK),("ana",P_ANA_D),("dig",G_DIG_D),("amb",AMB_D),("tea",TEA_D),("rus",RUS_D)]:
    add(f'<marker id="ar_{nm}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7.5" markerHeight="7.5" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{col}"/></marker>')
add('</defs>')
def box(x,y,w,h,fill,stroke,sw=2.0,rx=6): add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
def line(x1,y1,x2,y2,col=INK,sw=1.8,dash=None,marker=None):
    d=f' stroke-dasharray="{dash}"' if dash else ""; m=f' marker-end="url(#ar_{marker})"' if marker else ""
    add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{col}" stroke-width="{sw}"{d}{m}/>')
def poly(pts,col,sw,marker=None,fill="none"):
    m=f' marker-end="url(#ar_{marker})"' if marker else ""
    add(f'<polyline points="{pts}" fill="{fill}" stroke="{col}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"{m}/>')
def txt(x,y,t,size=16,col=INK,anchor="middle",weight="normal",style="normal"): add(f'<text x="{x}" y="{y}" font-size="{size}" fill="{col}" text-anchor="{anchor}" font-weight="{weight}" font-style="{style}">{t}</text>')
def circ(cx,cy,r,fill,stroke,sw=1.5): add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
def diamond(cx,cy,r,fill,stroke,sw=2.0): add(f'<path d="M{cx} {cy-r} L{cx+r} {cy} L{cx} {cy+r} L{cx-r} {cy} z" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
def tri(x,y,col): add(f'<path d="M{x-14} {y-7} L{x-1} {y} L{x-14} {y+7} z" fill="{col}"/>')
def xmark(cx,cy,r,col): poly(f"{cx-r},{cy-r} {cx+r},{cy+r}",col,3.6); poly(f"{cx-r},{cy+r} {cx+r},{cy-r}",col,3.6)
def check(cx,cy,r,col): poly(f"{cx-r},{cy} {cx-r*0.25},{cy+r*0.8} {cx+r},{cy-r*0.9}",col,3.6)
def crossbar(ox,oy,pitch,protected,vacate):
    xs=[ox+i*pitch for i in range(5)]; ys=[oy+j*pitch for j in range(5)]
    left=ox-pitch*0.5; bottom=ys[-1]+pitch*0.5; top=oy-pitch*0.32
    rc=pitch*0.22; rd=pitch*0.28; rv=pitch*0.25
    for y in ys: line(left,y,xs[-1]+pitch*0.30,y,col=GRY,sw=1.4); tri(left,y,P_ANA_D)
    for x in xs: line(x,top,x,bottom,col=GRY,sw=1.4)
    for j,y in enumerate(ys):
        for i,x in enumerate(xs):
            if (i,j) in protected:
                if vacate: circ(x,y,rv,"#FFFFFF",GRY,1.6); txt(x,y+rv*0.55,"0",pitch*0.38,GRY,weight="bold")
                else: diamond(x,y,rd,AMB,AMB_D,2.3)
            else: circ(x,y,rc,P_ANA_L,P_ANA_D,1.6)
    return xs,ys,bottom
prot={(1,0),(3,1),(0,3),(2,4)}
DIV=562  # vertical divider x

# ===================== PANEL (a) — LEFT (top region) =====================
txt(30,58,"(a)",27,INK,anchor="start",weight="bold"); txt(86,58,"Constraint: a fixed PCM crossbar",27,INK,anchor="start",weight="bold")
gx,gy,gp=95,138,44; xs,ys,bot=crossbar(gx,gy,gp,prot,False)
txt(gx+2*gp,gy-36,"PCM crossbar",21,INK,style="italic")
txt(40,gy-12,"activations",21,P_ANA_D,anchor="start"); txt(40,gy+13,f"x{SUB_I}",21,P_ANA_D,anchor="start",style="italic")
busy=bot+8; line(xs[0]-8,busy,xs[-1]+13,busy,col=P_ANA_D,sw=3.2)
abx=xs[3]; aby=ys[1]; line(abx,aby,abx,busy,col=AMB_D,sw=4.4,marker="amb")
txt(gx+2*gp,busy+28,f"{SIG} column current = {SIG}{SUB_I} G{SUB_I} x{SUB_I}",21,P_ANA_D)
adcy=busy+50; acx=gx+2*gp; box(acx-76,adcy,152,52,P_ANA_L,P_ANA_D,2.1); txt(acx,adcy+33,"5-bit ADC",25,P_ANA_D,weight="bold")
line(acx,busy,acx,adcy,col=P_ANA_D,sw=2.1,marker="ana")
rax=295
line(abx+13,aby,rax-9,184,col=AMB_D,sw=1.5,dash="3 3")
txt(rax,178,"drift-sensitive weights",22,AMB_D,anchor="start",weight="bold")
txt(rax,206,"(largest |w| in each layer)",21,AMB_D,anchor="start")
txt(rax,246,"They drift in place; their",19,INK,anchor="start")
txt(rax,272,f"currents merge into one {SIG}.",19,INK,anchor="start")

# ===================== PANEL (b) — RIGHT (top region) =====================
txt(588,58,"(b)",27,INK,anchor="start",weight="bold"); txt(644,58,"Realization without changing the crossbar",27,INK,anchor="start",weight="bold")
# col1: bitmap + crossbar + ADC
bmx,bmy=586,140; bits=[0,1,0,0,1,0,1]; bcw=30; bcp=30
txt(bmx,bmy-14,"one bit per weight",19,INK,anchor="start",weight="bold")
for k,b in enumerate(bits):
    fx=bmx+k*bcp; col=TEA_L if b else P_ANA_L; cd=TEA_D if b else P_ANA_D
    box(fx,bmy,bcw,bcw,col,cd,1.8,rx=3); txt(fx+bcw/2,bmy+21,str(b),22,cd,weight="bold")
bmr=bmx+len(bits)*bcp
cbx,cby,cbp=600,212,34; xs2,ys2,bot2=crossbar(cbx,cby,cbp,prot,True)
busy2=bot2+6; line(xs2[0]-8,busy2,xs2[-1]+13,busy2,col=P_ANA_D,sw=3.0)
adcy2=busy2+30; acx2=cbx+2*cbp; box(acx2-76,adcy2,152,52,P_ANA_L,P_ANA_D,2.1); txt(acx2,adcy2+33,"5-bit ADC",25,P_ANA_D,weight="bold")
line(acx2,busy2,acx2,adcy2,col=P_ANA_D,sw=2.1,marker="ana")
# routes (color-coded: purple 0->crossbar, teal 1->SRAM)
line(bmx+bcw/2,bmy+bcw,bmx+bcw/2,cby-cbp*0.32-4,col=P_ANA_D,sw=2.0,dash="4 3",marker="ana")
# col2: SRAM partition + compact address map
sx,sy=828,150; box(sx,sy,272,70,TEA_L,TEA_D,2.2); txt(sx+136,sy+29,"SRAM partition",24,TEA_D,weight="bold"); txt(sx+136,sy+54,"protected weights (INT8)",21,TEA_D)
amx,amy=828,242; box(amx,amy,272,70,RUS_L,RUS_D,2.2); txt(amx+136,amy+29,"compact address map",24,RUS_D,weight="bold"); txt(amx+136,amy+54,f"{AP}25{MUL} smaller than flat tables",20,RUS_D)
line(amx+136,amy,sx+136,sy+70,col=RUS_D,sw=1.8,marker="rus"); txt(amx+136,amy+92,"gives the bit and the slot",20,RUS_D); txt(amx+136,amy+116,"of every weight",20,RUS_D)
line(amx,amy+20,bmr-10,bmy+bcw+3,col=RUS_D,sw=1.6,dash="3 3",marker="rus")
line(bmr,bmy+bcw/2,sx,sy+22,col=TEA_D,sw=2.0,dash="4 3",marker="tea"); txt(bmr+12,bmy+2,f"1 {ARR} SRAM",20,TEA_D,anchor="start")
# col3: accumulator + requantize + output
axx,ayy=1124,170; box(axx,ayy,170,74,G_DIG_L,G_DIG_D,2.3); txt(axx+85,ayy+31,"digital",24,G_DIG_D,weight="bold"); txt(axx+85,ayy+57,"accumulator",22,G_DIG_D,weight="bold")
line(sx+272,sy+26,axx,ayy+24,col=TEA_D,sw=2.1,marker="tea"); txt((sx+272+axx)/2,sy-8,"exact products",20,TEA_D)
gxr=1108
poly(f"{acx2+76},{adcy2+24} {gxr},{adcy2+24} {gxr},{ayy+50} {axx},{ayy+50}",INK,2.1,marker="ink")
txt(acx2+90,adcy2+44,"analog partial sum",20,P_ANA_D,anchor="start")
rqy=ayy+104; box(axx,rqy,170,56,G_DIG_L,G_DIG_D,1.8); txt(axx+85,rqy+24,"requantize",20,G_DIG_D); txt(axx+85,rqy+47,"+ ReLU",20,G_DIG_D)
line(axx+85,ayy+74,axx+85,rqy,col=G_DIG_D,sw=2.1,marker="dig")
line(axx+85,rqy+56,axx+85,rqy+78,col=INK,sw=2.1,marker="ink"); txt(axx+85,rqy+98,"to next layer",21,INK)

# ===================== bottom takeaway boxes (aligned) =====================
TBY,TBH=470,104
# (a) red box
box(30,TBY,515,TBH,RED_L,RED,2.1,rx=10); xmark(66,TBY+TBH/2,13,RED)
txt(98,TBY+44,"A scattered, magnitude-chosen subset cannot be",17,INK,anchor="start")
txt(98,TBY+72,"exempted from the collective analog column sum.",17,INK,anchor="start")
# (b) green box
box(580,TBY,710,TBH,G_DIG_L,G_DIG_D,2.1,rx=10); check(618,TBY+TBH/2,13,G_DIG_D)
txt(650,TBY+44,"Protected weights are vacated to an exact SRAM partition,",17,INK,anchor="start")
txt(650,TBY+72,f"located by a compact {AP}25{MUL} map and re-added; the crossbar is unchanged.",17,INK,anchor="start")

# ===================== dividers + shared legend =====================
line(DIV,38,DIV,594,col=GRY_L,sw=1.8)            # vertical between (a) and (b)
line(30,612,1290,612,col=GRY_L,sw=1.5)           # horizontal above legend
LX=(62,470,890); ly1,ly2=646,688
circ(LX[0],ly1,10,P_ANA_L,P_ANA_D,1.6); txt(LX[0]+22,ly1+7,"PCM cell (analog, drifts)",22,INK,anchor="start")
diamond(LX[1],ly1,12,AMB,AMB_D,2.3); txt(LX[1]+24,ly1+7,"drift-sensitive weight (to protect)",22,INK,anchor="start")
circ(LX[2],ly1,11,"#FFFFFF",GRY,1.6); txt(LX[2],ly1+6,"0",14,GRY,weight="bold"); txt(LX[2]+22,ly1+7,"vacated crossbar position",22,INK,anchor="start")
box(LX[0]-12,ly2-12,24,24,G_DIG_L,G_DIG_D,1.8,rx=3); txt(LX[0]+22,ly2+7,"digital logic",22,INK,anchor="start")
box(LX[1]-12,ly2-12,24,24,TEA_L,TEA_D,1.8,rx=3); txt(LX[1]+24,ly2+7,"SRAM partition",22,INK,anchor="start")
box(LX[2]-12,ly2-12,24,24,RUS_L,RUS_D,1.8,rx=3); txt(LX[2]+22,ly2+7,"address map (ROM)",22,INK,anchor="start")
add('</svg>')

svg="\n".join(s); BASE=os.path.join(_a.out,"fig01_concept")
open(BASE+".svg","w",encoding="utf-8").write(svg)
import cairosvg
cairosvg.svg2png(bytestring=svg.encode("utf-8"),write_to=BASE+".png",output_width=2600)
cairosvg.svg2pdf(bytestring=svg.encode("utf-8"),write_to=BASE+".pdf")
print("wrote", BASE + ".svg/.png/.pdf")
