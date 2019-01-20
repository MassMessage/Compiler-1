/**
 * Implementation of the
 * $(LINK2 http://www.digitalmars.com/download/freecompiler.html, Digital Mars C/C++ Compiler).
 *
 * Copyright:   Copyright (c) 1984-1998 by Symantec, All Rights Reserved
 *              Copyright (c) 2000-2017 by Digital Mars, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     Distributed under the Boost Software License, Version 1.0.
 *              http://www.boost.org/LICENSE_1_0.txt
 * Source:      https://github.com/DigitalMars/Compiler/blob/master/dm/src/dmc/dmsc.d
 */

// Miscellaneous routines for compiler

module dmsc;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.backend.cdef;
import dmd.backend.cc;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.type;

import dmd.backend.dlist;
import dmd.backend.memh;

import dcpp;
import msgs2;
import parser;
import precomp;

extern (C++):

int REGSIZE(); //{ return _tysize[TYnptr]; }

/*********************** COMMON FUNCTIONS ********************/

/*******************************
 * Compute size of type in bytes.
 */

targ_size_t size(tym_t ty)
{       int s;

        if (tybasic(ty) == TYvoid)
            s = 1;
        else
            s = tysize(ty);

debug
{
version (SPP)
{
}
else
{
        if (s == -1)
            WRTYxx(ty);
}
}
        assert(s != -1);
        return s;
}

version (SPP)
{
}
else
{

/****************************
 * Add symbol to the symbol table referring to the DATA segment
 * at offset.
 */

Symbol *symboldata(targ_size_t offset,tym_t ty)
{   Symbol *s;

    s = symbol_generate(SClocstat,type_fake(ty));
    s.Sfl = FLdata;
    s.Soffset = offset;
    s.Sseg = DATA;
    symbol_keep(s);                     // free when program terminates
    return s;
}

/*****************************
 * Create a new type that's a pointer
 * to an existing type.
 */

type *newpointer(type *t)
{   tym_t tym;

    assert(t);
    type_debug(t);
    switch (tybasic(t.Tty))
    {
        case TYnfunc:
        case TYnpfunc:
        case TYnsfunc:
        case TYnsysfunc:
            tym = TYnptr;
            break;
        case TYf16func:
            tym = TYf16ptr;
            break;
        case TYfsfunc:
        case TYfsysfunc:
        case TYifunc:
        //case TYpsfunc:
        case TYffunc:
        case TYfpfunc:
            tym = TYfptr;
            break;

        case TYvoid:
            if (t.Tty != TYvoid)
                goto default;
            return tspvoid;

        case TYstruct:
            tym = t.Ttag.Sstruct.ptrtype;
            if (tym)
                break;
            goto default;

        default:
            tym = pointertype;
            break;
    }
    return type_allocn(tym,t);
}

/*****************************
 * Create a new type that's a pointer
 * to an existing type. Type not modified.
 */

type *newpointer_share(type *t)
{   tym_t tym;

    type_debug(t);
    tym = tybasic(t.Tty);
    if (t == tstypes[tym])
    {   //printf("shared type "); WRTYxx(tym); printf("\n");
        t = tsptr2types[tym];
        type_debug(t);
        //type_print(t);
        return t;
    }
    return newpointer(t);
}

/*****************************
 * Convert 'reference to' to 'pointer to'.
 */

type *reftoptr(type *t)
{   type *et;
    tym_t ty;

    switch (tybasic(t.Tty))
    {
static if (TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_OPENBSD || TARGET_SOLARIS)
{
        case TYnref:
        case TYfref:
            ty = TYnptr;
}
else
{
        case TYnref:
            ty = TYnptr;
            goto L1;
        case TYfref:
            ty = TYfptr;
        L1:
}
            et = type_allocn(ty,t.Tnext);
            break;

        default:
            et = newpointer(t.Tnext);
            break;
    }
    return et;
}

/*****************************
 * Create a new type that's a reference
 * to an existing type.
 */

type *newref(type *t)
{
    return type_allocn(TYref,t);
}

/********************************
 * Convert <array of> to <pointer to>.
 */

type *topointer(type *t)
{   type *tn;

    /* NULL pointers are the result of error recovery   */
    if (t && tybasic(t.Tty) == TYarray)
    {   tn = newpointer(t.Tnext);
static if (TARGET_WINDOS)
{
        if (t.Tty & mTYfar && tybasic(tn.Tty) == TYnptr)
            tn.Tty = (tn.Tty & ~mTYbasic) | TYfptr;
}
        tn.Tcount++;

        // Transfer over type-qualifier-list
        type_setty(&tn, tn.Tty | (t.Tty & (mTYconst | mTYvolatile | mTYrestrict | mTYunaligned)));

        type_free(t);
        t = tn;
    }
    return t;
}

/***************************
 * Return a type that is a pointer to an elem.
 */

type *type_ptr(elem *e,type *t)
{   type *tptr;

    tptr = newpointer(t);
    if (e.Eoper == OPind)
    {   type *t1 = e.EV.E1.ET;

        if (typtr(t1.Tty))
            tptr.Tty = t1.Tty;
    }
    else if (e.ET.Tty & mTYfar)
        tptr.Tty = TYfptr;
    else if (e.ET.Tty & mTYcs)
        tptr.Tty = TYcptr;
    else if (e.Eoper == OPvar || e.Eoper == OPrelconst)
    {
        // Don't change type if type was fixed by class pointer type
        if (!CPP ||
            tybasic(t.Tty) != TYstruct ||
            t.Ttag.Sstruct.ptrtype == 0)
        {
            switch (e.EV.Vsym.Sclass)
            {   case SCauto:
                case SCparameter:
                case SCregister:
                case SCregpar:
                case SCfastpar:
                case SCshadowreg:
                case SCbprel:
static if (TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_OPENBSD || TARGET_SOLARIS)
{
                    tptr.Tty = TYnptr;
}
else
{
                    tptr.Tty = (config.wflags & WFssneds) ? TYsptr : TYnptr;
}
                    break;
                case SCglobal:
                case SCstatic:
                case SCextern:
                case SCcomdef:
                case SCcomdat:
                    if (!tyfunc(t.Tty))        /* handled by newpointer() */
                        tptr.Tty = TYnptr;
                    break;

                default:
                    break;
            }
        }
    }
    return tptr;
}

/******************************
 * If type is an array, look for what it's an array of.
 */

type *type_arrayroot(type *t)
{
    type_debug(t);
    while (tybasic(t.Tty) == TYarray)
    {   t = t.Tnext;
        type_debug(t);
    }
    return t;
}

/**********************************
 * Give error message if size is wrong.
 */

int type_chksize(uint u)
{   int result;

    if (u > 0xFFFF && _tysize[TYint] == 2)
    {   synerr(EM_typesize_gt64k);      // size exceeds 64k
        result = 1;
    }
    else
        result = 0;
    return result;
}

/**********************************
 * Compute type mask of C type that is the
 * translation of a C++ type.
 */

tym_t tym_conv(const type *t)
{   tym_t tym = t.Tty;
    tym_t nty;

// We can have reference types for __out(__result) { ... }
//    if (!CPP)
//      return tym;
    switch (tybasic(tym))
    {
        case TYmemptr:
            switch (tybasic(t.Tnext.Tty))
            {
                case TYffunc:
                case TYfpfunc:
                case TYfsfunc:
                case TYfsysfunc:
                case TYifunc:
                    nty = TYfptr;
                    break;

                case TYnfunc:
                case TYnpfunc:
                case TYnsfunc:
                case TYnsysfunc:
                    nty = TYnptr;
                    break;

                case TYf16func:
                    nty = TYf16ptr;
                    break;

                default:
                    nty = TYuint;
                    break;
            }
            break;
        case TYbool:
            nty = TYchar;
            break;
        case TYwchar_t:
        case TYchar16:
            nty = TYushort;
            break;
        case TYdchar:
            nty = TYulong;
            break;
        case TYenum:
            nty = t.Tnext.Tty;
            break;
        case TYref:
            if (type_struct(t.Tnext))  // if reference to struct
            {   nty = t.Tnext.Ttag.Sstruct.ptrtype;
                if (nty)
                    break;
            }
            nty = pointertype;
            break;
        case TYfref:
            nty = TYfptr;
            break;
        case TYnref:
            nty = TYnptr;
            break;
        case TYvtshape:
            symbol_debug(s_mptr);
            nty = tybasic(s_mptr.Stype.Tty);
            break;
        case TYnullptr:
            nty = pointertype;
            break;

        default:
            nty = tym;
            break;
    }
    tym = (tym & ~mTYbasic) | nty;      /* preserve const and volatile bits */
    return tym;
}

/*****************************
 * Check that e.EV.E1 is a valid lvalue. e could be an assignment operator
 * or a & operator.
 */

void chklvalue(elem *e)
{   tym_t tym;
    elem *e1;
    elem *e12;

    elem_debug(e);
    e1 = e.EV.E1;
L1:
    assert(!OTleaf(e.Eoper) && e1.ET);   /* make sure it's an operator node */
    if (e1.PEFflags & PEFnotlvalue)
        goto Lerror;
    switch (e1.Eoper)
    {
        case OPvar:
            if (config.ansi_c)
            {
                /* ANSI 3.3.3.1 lvalue cannot be cast   */
                if (!typematch(e1.EV.Vsym.Stype,e1.ET,0) &&
                    // Allow anonymous unions
                    memcmp(e1.EV.Vsym.Sident.ptr, "_anon_".ptr, 6))
                {   synerr(EM_lvalue);
                    break;
                }
            }
            goto case OPbit;
        case OPbit:
        case OPind:
            tym = tybasic(e1.ET.Tty);
            if (!(tyscalar(tym) ||
                  tym == TYstruct ||
                  tym == TYarray && e.Eoper == OPaddr))
                    synerr(EM_lvalue);  // lvalue expected
            break;

        case OPcond:
            // convert (a ? b : c) to *(a ? &b : &c)
            if (!CPP)
                goto Lerror;
            e12 = e1.EV.E2;
            e12.EV.E1 = exp2_addr(e12.EV.E1);
            chklvalue(e12.EV.E1);
            e12.EV.E2 = exp2_addr(e12.EV.E2);
            chklvalue(e12.EV.E2);
            exp2_ptrtocomtype(e12);
            el_settype(e12,e12.EV.E2.ET);
            el_settype(e1,e12.ET);
            e.EV.E1 = el_unat(OPind,e1.ET.Tnext,e1);
            break;

        case OPcomma:
            e1 = e1.EV.E2;
            goto L1;

        default:
        Lerror:
            synerr(EM_lvalue);          // lvalue expected
            break;
    }
}

/**********************************
 * Check that we can assign to e.EV.E1.
 * (That is, e.EV.E1 is a modifiable lvalue.)
 */

void chkassign(elem *e)
{   elem *e1;

    chklvalue(e);                       // e.EV.E1 must be an lvalue

    /* e.EV.E1 must be a modifiable lvalue. That is (ANSI 3.2.2.1):
        o       Not an array type
        o       Not an incomplete type
        o       Not a const-qualified type
        o       Not a struct or union with a const-qualified member
                (applied recursively)
     */
    e1 = e.EV.E1;
    if (e1.ET.Tty & mTYconst)
    {   const(char)* p;
        bool freeit = false;
        char* s;

        if (e1.Eoper == OPvar)
            p = prettyident(e1.EV.Vsym);
        else if (e1.Eoper == OPind && e1.EV.E1.Eoper == OPvar)
        {   p = prettyident(e1.EV.E1.EV.Vsym);
            {
                //p = alloca_strdup2("*",p);
                size_t len = strlen(p);
                s = cast(char*)mem_malloc(1 + len + 1);
                s[0] = '*';
                p = cast(const(char)*)memcpy(s + 1, p, len + 1);
                freeit = true;
            }
        }
        else
            p = "".ptr;
        synerr(EM_const_assign,p);      // can't assign to const variable
        if (freeit)
            mem_free(s);
    }

    if (OTopeq(e.Eoper))
    {
        chknosu(e1);
    }
}

/*****************************
 */

void chknosu(elem *e)
{
    elem_debug(e);
    switch (tybasic(e.ET.Tty))
    {   case TYstruct:
            synerr(EM_bad_struct_use);          // no structs or unions here
            break;
        case TYvoid:
            synerr(EM_void_novalue);
            break;
        case TYnullptr:
            synerr(EM_no_nullptr_bool);
            break;
        default:
            break;
    }
}

/*****************************
 */

void chkunass(elem *e)
{
    elem_debug(e);
    if (e.Eoper == OPeq)
        warerr(WM.WM_assignment);          // possible unintended assignment
}

/*****************************
 * Prevent instances of abstract classes.
 */

void chknoabstract(type *t)
{
    /* Cannot create instance of abstract class */
    t = type_arrayroot(t);
    if (tybasic(t.Tty) == TYstruct &&
        t.Ttag.Sstruct.Sflags & STRabstract)
        cpperr(EM_create_abstract,prettyident(t.Ttag));        // abstract class
}

/**********************************
 * Evaluate an integer expression.
 * Returns:
 *      result of expression
 */

targ_llong msc_getnum()
{   elem *e;
    targ_llong i;

    e = CPP ? assign_exp() : const_exp();
    if (config.ansi_c && !tyintegral(e.ET.Tty))
        synerr(EM_integral);            // integral expression expected
    e = poptelem3(e);
    if (e.Eoper == OPconst)            // if result is a constant
        i = el_tolong(e);
    else
    {   synerr(EM_num);                 // number expected
        i = 0;
    }
    el_free(e);
    return i;
}


/****************************
 * Do byte or word alignment as necessary.
 * Align sizes of 0, as we may not know array sizes yet.
 */

targ_size_t alignmember(type *t,targ_size_t size,targ_size_t offset)
{   uint salign;

    t = type_arrayroot(t);
    if (type_struct(t))
        salign = t.Ttag.Sstruct.Sstructalign;
    else
        salign = structalign;
    //printf("salign = %d, size = %d, offset = %d\n",salign,size,offset);
    if (salign)
    {   int sa;

        switch (size)
        {   case 1:
                break;
            case 2:
            case_2:
                offset = (offset + 1) & ~1;     // align to word
                break;
            case 3:
            case 4:
                if (salign == 1)
                    goto case_2;
                offset = (offset + 3) & ~3;     // align to dword
                break;
            default:
                offset = (offset + salign) & ~salign;
                break;
        }
    }
    //printf("result = %d\n",offset);
    return offset;
}

/*********************************
 * Do byte or word alignment as necessary.
 */

targ_size_t _align(targ_size_t size,targ_size_t offset)
{
    switch (size)
    {
        case 1:
            break;
        case 2:
            offset = (offset + 1) & ~1;
            break;
        case 4:
            offset = (offset + 3) & ~3;
            break;
        case 8:
            offset = (offset + 7) & ~7;
            break;
        default:
            offset = (offset + REGSIZE - 1) & ~(REGSIZE - 1);
            break;
    }
    return offset;
}


/***************************************
 * Hydrate/dehydrate a list.
 */

static if (HYDRATE)
{
void list_hydrate(list_t *plist,void function(void *) hydptr)
{
    list_t l;

    while (isdehydrated(*plist))
    {
        l = cast(list_t)ph_hydrate(cast(void**)plist);
        plist = &l.next;
        if (hydptr)
            (*hydptr)(&l.ptr);
        else
            ph_hydrate(&l.ptr);
    }
}
}

static if (DEHYDRATE)
{
void list_dehydrate(list_t *plist,void function(void *) dehydptr)
{
    list_t l;

    while ((l = *plist) != null &&      /* while not end of list and    */
           !isdehydrated(l))            /* not already dehydrated       */
    {
        ph_dehydrate(plist);
version (DEBUG_XSYMGEN)
{
        if (xsym_gen && ph_in_head(l))
            return;
}
        plist = &l.next;
        if (dehydptr)
            (*dehydptr)(&list_ptr(l));
        else
            ph_dehydrate(&list_ptr(l));
    }
}
}

/***************************************
 * Hydrate/dehydrate a list of ints.
 */

static if (HYDRATE)
{
void list_hydrate_d(list_t *plist)
{   list_t l;

    while (isdehydrated(*plist))
    {
        l = cast(list_t)ph_hydrate(cast(void**)plist);
        plist = &l.next;
    }
}
}

static if (DEHYDRATE)
{
void list_dehydrate_d(list_t *plist)
{
    list_t l;

    while ((l = *plist) != null &&      /* while not end of list and    */
           !isdehydrated(l))            /* not already dehydrated       */
    {
        ph_dehydrate(plist);
version (DEBUG_XSYMGEN)
{
        if (xsym_gen && ph_in_head(l))
            return;
}
        plist = &list_next(l);
    }
}
}


}
