//
//  iTermParser.h
//  iTerm2
//
//  Created by George Nachman on 1/5/15.
//
//  Utilities for parsing escape codes.

#import "NSStringITerm.h"

typedef struct {
    // Pointer to next character to read.
    unsigned char *datap;
    // Number of valid bytes starting at datap.
    int datalen;
    // Number of bytes already consumed. Subtract this from datap to get the original value of datap.
    int rmlen;
} iTermParserContext;

NS_INLINE iTermParserContext iTermParserContextMake(unsigned char *datap, int length) {
    iTermParserContext context = {
        .datap = datap,
        .datalen = length,
        .rmlen = 0
    };
    return context;
}

NS_INLINE NSString *iTermParserDebugString(iTermParserContext *context) {
    NSData *data = [NSData dataWithBytes:context->datap length:context->datalen];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByReplacingControlCharactersWithCaretLetter];
}

NS_INLINE BOOL iTermParserCanAdvance(iTermParserContext *context) {
    return context->datalen > 0;
}

NS_INLINE unsigned char iTermParserPeek(iTermParserContext *context) {
    return context->datap[0];
}

NS_INLINE BOOL iTermParserTryPeek(iTermParserContext *context, unsigned char *c) {
    if (iTermParserCanAdvance(context)) {
        *c = iTermParserPeek(context);
        return YES;
    } else {
        return NO;
    }
}

NS_INLINE void iTermParserAdvance(iTermParserContext *context) {
    context->datap++;
    context->datalen--;
    context->rmlen++;
}

NS_INLINE void iTermParserAdvanceMultiple(iTermParserContext *context, int n) {
    assert(context->datalen >= n);
    context->datap += n;
    context->datalen -= n;
    context->rmlen += n;
}

NS_INLINE BOOL iTermParserTryAdvance(iTermParserContext *context) {
    if (!iTermParserCanAdvance(context)) {
        return NO;
    }
    iTermParserAdvance(context);
    return YES;
}

NS_INLINE NSInteger iTermParserNumberOfBytesConsumed(iTermParserContext *context) {
    return context->rmlen;
}

// Only safe to call if iTermParserCanAdvance returns YES.
NS_INLINE unsigned char iTermParserConsume(iTermParserContext *context) {
    unsigned char c = context->datap[0];
    iTermParserAdvance(context);
    return c;
}

NS_INLINE BOOL iTermParserTryConsume(iTermParserContext *context, unsigned char *c) {
    if (!iTermParserCanAdvance(context)) {
        return NO;
    }
    *c = iTermParserConsume(context);
    return YES;
}

NS_INLINE void iTermParserConsumeOrDie(iTermParserContext *context, unsigned char expected) {
    unsigned char actual;
    BOOL consumedOk = iTermParserTryConsume(context, &actual);

    assert(consumedOk);
    assert(actual == expected);
}

NS_INLINE void iTermParserBacktrackBy(iTermParserContext *context, int n) {
    context->datap -= n;
    context->datalen += n;
    context->rmlen -= n;
}

NS_INLINE void iTermParserBacktrack(iTermParserContext *context) {
    iTermParserBacktrackBy(context, context->rmlen);
}

NS_INLINE int iTermParserNumberOfBytesUntilCharacter(iTermParserContext *context, unsigned char c) {
    unsigned char *pointer = (unsigned char *)memchr(context->datap, c, context->datalen);
    if (!pointer) {
        return -1;
    } else {
        return (int)(pointer - context->datap);
    }
}

NS_INLINE int iTermParserLength(iTermParserContext *context) {
    return context->datalen;
}

NS_INLINE unsigned char *iTermParserPeekRawBytes(const iTermParserContext *context, int length) {
    if (context->datalen < length) {
        return NULL;
    } else {
        return context->datap;
    }
}

// Returns YES if any digits were found, NO if the first character was not a digit. |n| must be a
// valid pointer. It will be filled in with the integer at the start of the context and the context
// will be advanced to the end of the integer.
NS_INLINE BOOL iTermParserConsumeInteger(iTermParserContext *context, int *n, BOOL *overflowPtr) {
    int numDigits = 0;
    *n = 0;
    unsigned char c;
    while (iTermParserCanAdvance(context) &&
           isdigit((c = iTermParserPeek(context)))) {
        ++numDigits;
        if (*n > (INT_MAX - 10) / 10) {
            *overflowPtr = YES;
        } else {
            *n *= 10;
            *n += (c - '0');
        }
        iTermParserAdvance(context);
    }
    *overflowPtr = NO;
    return numDigits > 0;
}

#pragma mark - CSI

#define VT100CSIPARAM_MAX 16  // Maximum number of CSI parameters in VT100Token.csi->p.
#define VT100CSISUBPARAM_MAX 16  // Maximum number of CSI sub-parameters in VT100Token.csi->p.

typedef struct {
    // Integer parameters. The first |count| elements are valid. -1 means the value is unset; set
    // values are always nonnegative.
    int p[VT100CSIPARAM_MAX];

    // Number of defined values in |p|.
    int count;

    // An integer that holds a packed representation of the prefix byte, intermediate byte, and
    // final byte.
    int32_t cmd;

    struct {
        int parameter_index;
        int subparameter_index;
        int value;
    } subparameters[VT100CSISUBPARAM_MAX];
    int num_subparameters;
} CSIParam;

static inline NSString *CSIParamDescription(CSIParam csi) {
    NSMutableArray *parameterStrings = [NSMutableArray array];

    for (int i = 0; i < csi.count; i++) {
        // For an unset parameter, add an empty string.
        if (csi.p[i] == -1) {
            [parameterStrings addObject:@""];
            continue;
        }

        NSMutableArray<NSString *> *subs = [NSMutableArray array];
        [subs addObject:[@(csi.p[i]) stringValue]];

        // Make a dictionary from subparameter index to value.
        NSMutableDictionary<NSNumber *, NSNumber *> *subDict = [NSMutableDictionary dictionary];
        int maxSubIndex = -1;
        for (int j = 0; j < csi.num_subparameters; j++) {
            if (csi.subparameters[j].parameter_index == i) {
                int subIdx = csi.subparameters[j].subparameter_index;
                subDict[@(subIdx)] = @(csi.subparameters[j].value);
                if (subIdx > maxSubIndex) {
                    maxSubIndex = subIdx;
                }
            }
        }

        // Add subparameters in order to subs
        if (maxSubIndex >= 0) {
            for (int subIndex = 0; subIndex <= maxSubIndex; subIndex++) {
                NSNumber *subValue = subDict[@(subIndex)];
                if (subValue) {
                    [subs addObject:[subValue stringValue]];
                } else {
                    [subs addObject:@""];
                }
            }
        }

        [parameterStrings addObject:[subs componentsJoinedByString:@":"]];
    }

    // Join all parameter strings with semicolons.
    return [parameterStrings componentsJoinedByString:@";"];
}

static inline void iTermParserAddCSIParameter(CSIParam *csi, int value) {
    if (csi->count + 1 >= VT100CSIPARAM_MAX) {
        // Avoid exceeding bounds; possibly discard or clamp this value.
        return;
    }
    csi->p[csi->count++] = value;
}

// Returns the number of subparameters for a particular parameter.
static inline int iTermParserGetNumberOfCSISubparameters(const CSIParam *csi, int parameter_index) {
    int count = 0;
    for (int j = 0; j < csi->num_subparameters; j++) {
        if (csi->subparameters[j].parameter_index == parameter_index) {
            count++;
        }
    }
    return count;
}

// Appends a subparameter for a parameter. Silently fails if there is not enough room.
static inline void iTermParserAddCSISubparameter(CSIParam *csi, int parameter_index, int value) {
    int i = csi->num_subparameters;
    if (i == VT100CSISUBPARAM_MAX) {
        return;
    }

    csi->subparameters[i].parameter_index = parameter_index;
    csi->subparameters[i].subparameter_index = iTermParserGetNumberOfCSISubparameters(csi, parameter_index);
    csi->subparameters[i].value = value;

    csi->num_subparameters++;
}

// Returns the value of a subparameter for some parameter. Returns -1 if it cannot be found.
static inline int iTermParserGetCSISubparameter(CSIParam *csi, int parameter_index, int subparameter_index) {
    int i = 0;
    for (int j = 0; j < csi->num_subparameters; j++) {
        if (csi->subparameters[j].parameter_index == parameter_index) {
            if (i == 0) {
                return csi->subparameters[j].value;
            }
            i--;
        }
    }
    return -1;
}

// Fills arrayToFill with subparameters for the given parameter index. Returns the number of subs.
static inline int iTermParserGetAllCSISubparametersForParameter(CSIParam *csi, int parameter_index, int arrayToFill[VT100CSISUBPARAM_MAX]) {
    int i = 0;
    for (int j = 0; j < csi->num_subparameters; j++) {
        if (csi->subparameters[j].parameter_index == parameter_index) {
            arrayToFill[i++] = csi->subparameters[j].value;
        }
    }
    return i;
}

// If the n'th parameter has a negative (default) value, replace it with |value|.
// CSI parameter values are all initialized to -1 before parsing, so this has the effect of setting
// a value iff it hasn't already been set.
// If there aren't yet n+1 parameters, increase the count to n+1.
NS_INLINE void iTermParserSetCSIParameterIfDefault(CSIParam *csiParam, int n, int value) {
    csiParam->p[n] = csiParam->p[n] < 0 ? value : csiParam->p[n];
    csiParam->count = MAX(csiParam->count, n + 1);
}

NS_INLINE BOOL iTermAddCSIParameter(CSIParam *csiParam, int value) {
    int index = csiParam->count;
    if (csiParam->count + 1 >= VT100CSIPARAM_MAX) {
        return NO;
    }
    csiParam->p[index] = value;
    csiParam->count += 1;
    return YES;
}
